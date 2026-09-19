require 'tmpdir'
require 'pathname'
require 'securerandom'

module MutationTester
  class MutationRunner
    CANARY_SOURCE = "raise 'mutation_tester canary: the workspace copy of this source was not executed'\n".freeze
    PARALLEL_INTERRUPT_LINE = "Parallel execution interrupted, exiting ...\n"

    class ParallelInterruptFilter
      def initialize(target)
        @target = target
      end

      def write(*args)
        return args.first.bytesize if args.length == 1 && args.first == PARALLEL_INTERRUPT_LINE

        @target.write(*args)
      end

      def respond_to_missing?(name, include_private = false)
        @target.respond_to?(name, include_private)
      end

      def method_missing(name, *args, &block)
        @target.send(name, *args, &block)
      end
    end
    private_constant :PARALLEL_INTERRUPT_LINE, :ParallelInterruptFilter

    def initialize(source_file, spec_file, original_content, config)
      @source_file = File.expand_path(source_file)
      @spec_file = File.expand_path(spec_file)
      @original_content = original_content
      @config = config
      @use_bundle_exec = TestCommand.use_bundle_exec?(@source_file)
    end

    def self.backup_path_for(source_file)
      "#{File.expand_path(source_file)}.mutation_backup"
    end

    def self.recover_in_place_backup(source_file)
      backup = backup_path_for(source_file)
      return false unless File.exist?(backup)

      File.write(File.expand_path(source_file), File.read(backup))
      File.delete(backup)
      true
    end

    def run(mutations, &progress_callback)
      announce_worker_env_in_memory_opt_out
      if in_memory_first? && @config.parallel_processes > 1
        run_in_memory_parallel(mutations, &progress_callback)
      elsif in_memory_first?
        run_in_memory_series(mutations, &progress_callback)
      elsif @config.parallel_processes == 1
        run_file_based_series(mutations, &progress_callback)
      else
        run_in_shadow_parallel(mutations, &progress_callback)
      end
    end

    def in_memory_first?
      return false unless %i[in_memory auto].include?(@config.runner)
      return true unless @config.worker_env_var

      @config.parallel_processes == 1 || !@config.after_fork_file.nil?
    end

    def run_in_memory_series(mutations, &progress_callback)
      blocker = prepare_in_memory_execution
      return fall_back_to_file_based(blocker, mutations, &progress_callback) if blocker

      warn '[MutationTester] In-memory execution selected (serial, zero file writes per mutant).'
      announce_load_time_routing(mutations)
      results = []
      begin
        mutations.each_with_index do |mutation, index|
          unless @in_memory_runner&.ready?
            return results + fall_back_to_file_based(
              'the in-memory worker terminated unexpectedly',
              mutations.drop(index), completed: index, &progress_callback
            )
          end

          result = run_single_mutation(mutation, :in_memory)
          progress_callback.call(mutation, index + 1, result) if progress_callback
          results << result
          break if stop_early?(result)
        end
      ensure
        shutdown_in_memory_worker
        cleanup_shadow_workspaces
      end
      results
    end

    def run_in_memory_parallel(mutations, &progress_callback)
      blocker = prepare_in_memory_execution
      return fall_back_to_parallel_file_based(blocker, mutations, &progress_callback) if blocker

      pool = ForkRunner.prepare_in_memory_pool(
        [@config.parallel_processes, mutations.size].min,
        @in_memory_runner,
        env_for: worker_env_for,
        after_fork: @config.after_fork_file
      )
      if pool.compact.empty?
        return fall_back_to_parallel_file_based('the preloaded worker pool could not be cloned', mutations, &progress_callback)
      end

      warn "[MutationTester] In-memory execution selected (parallel, #{pool.size} preloaded workers, zero file writes per mutant)."
      announce_load_time_routing(mutations)
      completed_count = 0
      collected = []
      project_root = discoverable_project_root
      reserve_fallback_shadow_root

      report_progress = lambda do |_item, _index, result|
        completed_count += 1
        collected << result
        progress_callback.call(nil, completed_count, result) if progress_callback
        raise Parallel::Break if stop_early?(result)
      end

      mapped = with_parallel_interrupt_silenced do
        Parallel.map(mutations, in_processes: pool.size, finish: report_progress) do |mutation|
          run_single_mutation(mutation, :in_memory, project_root)
        end
      end
      mapped || collected
    ensure
      ForkRunner.shutdown_in_memory_pool
      shutdown_in_memory_worker
      cleanup_shadow_workspaces
    end

    def run_in_shadow_parallel(mutations, &progress_callback)
      total = mutations.size
      completed_count = 0
      collected = []
      project_root = find_project_root
      shadow_run_root
      prepare_worker_preloads(total)

      report_progress = lambda do |_item, _index, result|
        completed_count += 1
        collected << result
        progress_callback.call(nil, completed_count, result) if progress_callback
        raise Parallel::Break if stop_early?(result)
      end

      mapped = with_parallel_interrupt_silenced do
        Parallel.map(mutations, in_processes: @config.parallel_processes, finish: report_progress) do |mutation|
          run_single_mutation(mutation, :shadow, project_root)
        end
      end
      mapped || collected
    ensure
      cleanup_shadow_workspaces
    end

    def run_file_based_series(mutations, &progress_callback)
      project_root = @config.worker_env_var ? discoverable_project_root : nil
      return run_in_place_series(mutations, &progress_callback) unless project_root

      run_in_shadow_series(mutations, project_root, &progress_callback)
    end

    def run_in_shadow_series(mutations, project_root, &progress_callback)
      warn "[MutationTester] --worker-env #{@config.worker_env_var} is set, so the serial run decides each mutant in a shadow workspace and never mutates the checkout in place."
      shadow_run_root
      results = []
      mutations.each_with_index do |mutation, index|
        result = run_single_mutation(mutation, :shadow, project_root)
        progress_callback.call(mutation, index + 1, result) if progress_callback
        results << result
        break if stop_early?(result)
      end
      results
    ensure
      cleanup_shadow_workspaces
    end

    def run_in_place_series(mutations, &progress_callback)
      write_in_place_backup
      results = []
      mutations.each_with_index do |mutation, index|
        result = run_single_mutation(mutation, :in_place)
        progress_callback.call(mutation, index + 1, result) if progress_callback
        results << result
        break if stop_early?(result)
      end
      results
    ensure
      restore_and_clear_in_place_backup
    end

    def run_single_mutation(mutation, strategy, project_root = nil)
      {
        id: mutation[:id],
        type: mutation[:type],
        line: mutation[:line],
        file_path: @source_file,
        original: mutation[:original],
        mutated: mutation[:mutated],
        source_line: mutation[:source_line],
        mutated_line: mutation[:mutated_line],
        killed: false,
        timeout: false,
        status: :survived,
        description: mutation[:description]
      }.tap do |result|
        if unparseable?(mutation[:code])
          mark_stillborn(result)
        elsif strategy == :in_memory && mutation[:in_memory_safe] == false
          run_mutation_load_time(mutation, result, project_root)
        elsif strategy == :in_memory
          run_mutation_in_memory(mutation, result, project_root)
        elsif strategy == :in_place
          run_mutation_in_place(mutation, result)
        else
          run_mutation_in_shadow(mutation, result, project_root)
        end
      end
    end

    def run_mutation_in_shadow(mutation, result, project_root)
      shadow_root = worker_shadow_root(project_root)

      relative_source = Pathname.new(@source_file).relative_path_from(Pathname.new(project_root)).to_s
      shadow_source = File.join(shadow_root, relative_source)
      relative_spec = Pathname.new(@spec_file).relative_path_from(Pathname.new(project_root)).to_s
      shadow_spec = File.join(shadow_root, relative_spec)

      begin
        File.unlink(shadow_source) if File.symlink?(shadow_source)
        File.write(shadow_source, mutation[:code])

        outcome, phase = run_two_phase(mutation) do |example_filters|
          run_specs_in_shadow(shadow_spec, shadow_root, project_root, example_filters: example_filters)
        end
        apply_outcome(result, outcome, phase)
      ensure
        restore_shadow_source(shadow_source, result)
      end
    rescue => e
      mark_error(result, e)
    end

    def cleanup_shadow_workspaces
      root = @shadow_run_root
      return unless root

      begin
        FileUtils.remove_entry(root) if File.directory?(root)
      rescue SystemCallError
        nil
      end
      @shadow_run_root = nil
      @worker_shadow_root = nil
    end

    def shadow_baseline_passes?
      shadow_workspace_check == :ok
    end

    def shadow_workspace_check
      project_root = find_project_root

      Dir.mktmpdir do |temp_dir|
        shadow_root = File.join(temp_dir, 'shadow')
        FileUtils.mkdir_p(shadow_root)
        shadow_copy_project(project_root, shadow_root)

        relative_source = Pathname.new(@source_file).relative_path_from(Pathname.new(project_root)).to_s
        shadow_source = File.join(shadow_root, relative_source)
        relative_spec = Pathname.new(@spec_file).relative_path_from(Pathname.new(project_root)).to_s
        shadow_spec = File.join(shadow_root, relative_spec)

        File.unlink(shadow_source)
        File.write(shadow_source, @original_content)
        return :baseline unless run_specs_in_shadow(shadow_spec, shadow_root, project_root).passed?

        File.write(shadow_source, CANARY_SOURCE)
        return :canary if run_specs_in_shadow(shadow_spec, shadow_root, project_root).passed?

        :ok
      end
    rescue => e
      warn("[MutationTester] Shadow sanity check could not prepare the shadow workspace: #{e.message}")
      :baseline
    end

    def shadow_copy_project(source, dest)
      if source == '/' || source.match?(%r{^/(usr|bin|sbin|etc|var|opt)$})
        raise MutationTester::Error, "Refusing to shadow copy system directory: #{source}"
      end

      Dir.glob("#{source}/*", File::FNM_DOTMATCH).each do |path|
        next if ['.', '..', '.git', 'tmp', 'log', 'coverage', 'node_modules'].include?(File.basename(path))

        basename = File.basename(path)
        target = File.join(dest, basename)

        if File.directory?(path) && !File.symlink?(path)
          FileUtils.mkdir_p(target)
          shadow_copy_project(path, target)
        elsif File.extname(path) == '.rb'
          FileUtils.copy_file(path, target)
        else
          File.symlink(path, target)
        end
      end
    end

    def run_specs_in_shadow(spec_file, working_dir, project_root, example_filters: [])
      test_command(spec_file, example_filters: example_filters)
        .run(timeout: @config.effective_timeout, chdir: working_dir, mirror_of: project_root)
    end

    def discoverable_project_root
      find_project_root
    rescue MutationTester::Error
      nil
    end

    def find_project_root
      current = File.dirname(File.expand_path(@source_file))
      loop do
        return current if File.exist?(File.join(current, 'Gemfile')) || File.exist?(File.join(current, '.git'))

        parent = File.dirname(current)

        if parent == current || parent == Dir.home || parent == '/'
          raise MutationTester::Error, "Could not find project root (looking for Gemfile or .git). Stopped at #{parent}"
        end

        current = parent
      end
    end

    def run_mutation_in_place(mutation, result)

      File.write(@source_file, mutation[:code])

      outcome, phase = run_two_phase(mutation) do |example_filters|
        run_specs_in_place(@spec_file, example_filters: example_filters)
      end
      apply_outcome(result, outcome, phase)
    rescue StandardError, Interrupt => e
      mark_error(result, e)
      raise e if e.is_a?(Interrupt)
    ensure
      File.write(@source_file, @original_content)
    end

    def run_specs_in_place(spec_file, example_filters: [])
      test_command(spec_file, example_filters: example_filters).run(timeout: @config.effective_timeout)
    end

    def run_mutation_in_memory(mutation, result, project_root = nil)
      runner = active_in_memory_runner
      return in_memory_worker_fallback(mutation, result, project_root, 'the in-memory worker is unavailable') unless runner&.ready?

      outcome = runner.execute_in_memory(
        source: mutation[:code],
        path: @source_file,
        timeout: @config.effective_timeout,
        chdir: Dir.pwd
      )

      if outcome.status == 'error'
        in_memory_apply_fallback(mutation, result, project_root, outcome.message || 'in-memory application failed')
      else
        apply_outcome(result, TestCommand::Result.new(outcome.status == 'pass', outcome.status == 'timeout'))
      end
    rescue MutationTester::Error => e
      return in_memory_worker_fallback(mutation, result, project_root, e.message) if project_root

      mark_error(result, e)
    rescue StandardError => e
      mark_error(result, e)
    end

    def run_two_phase(mutation)
      filters = subset_filters(mutation)
      unless filters.empty?
        subset_outcome = yield(filters)
        return [subset_outcome, :subset] unless subset_outcome.passed?
      end

      [yield([]), :full]
    end

    def subset_filters(mutation)
      return [] unless @config.test_selection
      return [] unless detect_test_framework(@spec_file) == :rspec

      method_name = mutation[:method_name].to_s
      return [] if method_name.empty?

      content = spec_content
      ["##{method_name}", ".#{method_name}"].select do |token|
        content.match?(/['"]#{Regexp.escape(token)}/)
      end
    end

    def detect_test_framework(spec_path)
      FrameworkDetector.detect(spec_path)
    end

    private

    def with_parallel_interrupt_silenced
      previous_stderr = $stderr
      $stderr = ParallelInterruptFilter.new(previous_stderr)
      yield
    ensure
      $stderr = previous_stderr
    end

    def prepare_in_memory_execution
      return 'Process.fork is not supported on this platform' unless ForkRunner.available?
      if @config.after_fork_file && !File.exist?(@config.after_fork_file)
        return "the after-fork file #{@config.after_fork_file} does not exist"
      end
      if InMemoryLoader.load_time_defined_guard?(@original_content)
        return 'the source file uses defined? at load time, so redefinition would silently skip the guarded code'
      end

      runner = ForkRunner.new(use_bundle_exec: @use_bundle_exec, framework: detect_test_framework(@spec_file))
      unless runner.ready?
        runner.shutdown
        return 'the in-memory worker failed to preload the environment'
      end

      preloaded, message = runner.preload(@spec_file, chdir: Dir.pwd, stop_on_first_failure: true)
      unless preloaded
        runner.shutdown
        return "the spec file could not be preloaded (#{message})"
      end

      probe = probe_in_memory_application(runner)
      return probe if probe

      @in_memory_runner = runner
      nil
    end

    def probe_in_memory_application(runner)
      outcome = runner.execute_in_memory(
        source: @original_content,
        path: @source_file,
        timeout: @config.effective_timeout,
        chdir: Dir.pwd
      )
      return nil if outcome.status == 'pass'

      runner.shutdown
      case outcome.status
      when 'error'
        "re-applying the unmutated source in memory failed (#{outcome.message})"
      when 'timeout'
        're-applying the unmutated source in memory exceeded the mutant deadline'
      else
        'the test suite fails after the unmutated source is re-applied in memory (load-time side effects?)'
      end
    rescue MutationTester::Error => e
      e.message
    end

    def fall_back_to_file_based(reason, mutations, completed: 0, &progress_callback)
      announce_file_based_fallback(reason)
      offset_callback = progress_callback && lambda do |mutation, index, result|
        progress_callback.call(mutation, completed + index, result)
      end
      run_file_based_series(mutations, &offset_callback)
    end

    def fall_back_to_parallel_file_based(reason, mutations, &progress_callback)
      announce_file_based_fallback(reason)
      return run_in_shadow_parallel(mutations, &progress_callback) if shadow_baseline_passes?

      warn '[MutationTester] The unmutated source fails inside the shadow workspace; finishing serially in place instead.'
      run_in_place_series(mutations, &progress_callback)
    end

    def announce_file_based_fallback(reason)
      label = test_command(@spec_file).fork_execution? ? 'fork' : 'spawn'
      warn "[MutationTester] In-memory execution is unavailable: #{reason}. Falling back to file-based execution (#{label})."
    end

    def announce_worker_env_in_memory_opt_out
      return unless @config.worker_env_var
      return unless %i[in_memory auto].include?(@config.runner)
      return if @config.parallel_processes == 1 || @config.after_fork_file

      warn "[MutationTester] --worker-env #{@config.worker_env_var} is set without --after-fork, so the in-memory runner is skipped (its clones share one preloaded database connection); using the fork runner for per-worker database isolation. Pass --after-fork FILE to keep the in-memory runner and re-establish per-worker connections inside each clone."
    end

    def run_mutation_load_time(mutation, result, project_root)
      root = project_root || discoverable_project_root
      return mark_error(result, MutationTester::Error.new('a load-time mutant needs a project root for file-based execution')) unless root

      run_mutation_in_shadow(mutation, result, root)
    end

    def announce_load_time_routing(mutations)
      return unless mutations.any? { |mutation| mutation[:in_memory_safe] == false }

      warn '[MutationTester] Some mutants affect load-time code (constants, class macros, included do); those run file-based so the in-memory score matches a full fork run.'
    end

    def in_memory_apply_fallback(mutation, result, project_root, reason)
      root = project_root || discoverable_project_root
      return mark_error(result, MutationTester::Error.new(reason)) unless root

      unless @in_memory_apply_fallback_announced
        @in_memory_apply_fallback_announced = true
        warn "[MutationTester] A mutant could not be applied in memory (#{reason}); deciding each such mutant file-based."
      end
      run_mutation_in_shadow(mutation, result, root)
    end

    def in_memory_worker_fallback(mutation, result, project_root, reason)
      return mark_error(result, MutationTester::Error.new(reason)) unless project_root

      unless @in_memory_fallback_announced
        @in_memory_fallback_announced = true
        warn "[MutationTester] An in-memory worker became unavailable (#{reason}); finishing its share of mutants file-based."
      end
      run_mutation_in_shadow(mutation, result, project_root)
    end

    def active_in_memory_runner
      return @in_memory_runner unless ForkRunner.in_memory_pool_prepared?

      ForkRunner.checkout_in_memory
    end

    def reserve_fallback_shadow_root
      @shadow_run_root ||= File.join(Dir.tmpdir, "mutation_tester_shadow-#{Process.pid}-#{SecureRandom.hex(8)}")
    end

    def shutdown_in_memory_worker
      runner = @in_memory_runner
      @in_memory_runner = nil
      runner&.shutdown
    end

    def prepare_worker_preloads(total)
      return unless test_command(@spec_file).fork_execution?

      ForkRunner.prepare_pool(
        [@config.parallel_processes, total].min,
        use_bundle_exec: @use_bundle_exec,
        framework: detect_test_framework(@spec_file),
        env_for: worker_env_for
      )
    end

    def worker_env_for
      return nil unless @config.worker_env_var

      ->(index) { @config.worker_env_assignment(index) }
    end

    def shadow_run_root
      @shadow_run_root ||= Dir.mktmpdir('mutation_tester_shadow')
    end

    def worker_shadow_root(project_root)
      if @worker_shadow_pid != Process.pid
        @worker_shadow_pid = Process.pid
        @worker_shadow_root = nil
      end

      @worker_shadow_root ||= build_worker_workspace(project_root)
    end

    def build_worker_workspace(project_root)
      @worker_workspace_serial = @worker_workspace_serial.to_i + 1
      root = File.join(shadow_run_root, "worker-#{Process.pid}-#{@worker_workspace_serial}")
      FileUtils.mkdir_p(root)
      shadow_copy_project(project_root, root)
      root
    end

    def restore_shadow_source(shadow_source, result)
      File.write(shadow_source, @original_content)
    rescue StandardError => e
      discard_worker_workspace
      mark_error(result, e)
    end

    def discard_worker_workspace
      root = @worker_shadow_root
      @worker_shadow_root = nil
      return unless root && File.directory?(root)

      FileUtils.remove_entry(root)
    rescue SystemCallError
      nil
    end

    def stop_early?(result)
      @config.fail_fast && result[:status] == :survived
    end

    def backup_path
      self.class.backup_path_for(@source_file)
    end

    def write_in_place_backup
      File.write(backup_path, @original_content)
    end

    def restore_and_clear_in_place_backup
      return unless File.exist?(backup_path)

      File.write(@source_file, File.read(backup_path))
      File.delete(backup_path)
    end

    def apply_outcome(result, outcome, phase = nil)
      if outcome.timed_out?
        result[:killed] = true
        result[:timeout] = true
        result[:status] = :timeout
      elsif outcome.passed?
        result[:status] = :survived
      else
        result[:killed] = true
        result[:status] = :killed
      end
      result[:kill_phase] = phase if result[:killed] && phase
    end

    def mark_stillborn(result)
      result[:status] = :stillborn
    end

    def mark_error(result, error)
      result[:killed] = false
      result[:timeout] = false
      result[:status] = :error
      result[:description] = "Error: #{error.message}"
    end

    def unparseable?(code)
      return false if code.nil?

      buffer = Parser::Source::Buffer.new('(mutant)')
      buffer.source = code
      parser = Parser::CurrentRuby.new
      parser.diagnostics.all_errors_are_fatal = true
      parser.diagnostics.ignore_warnings = true
      parser.parse(buffer)
      false
    rescue Parser::SyntaxError
      true
    end

    def spec_content
      @spec_content ||= File.exist?(@spec_file) ? File.read(@spec_file) : ''
    end

    def test_command(spec_file, example_filters: [])
      TestCommand.new(
        File.expand_path(spec_file),
        use_bundle_exec: @use_bundle_exec,
        runner: @config.runner,
        example_filters: example_filters,
        worker_env_var: @config.worker_env_var,
        stop_on_first_failure: true
      )
    end
  end
end
