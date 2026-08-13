require 'tempfile'

module MutationTester
  class TestCommand
    Result = Struct.new(:passed, :timed_out, :output) do
      alias_method :passed?, :passed
      alias_method :timed_out?, :timed_out
    end

    POLL_INTERVAL = 0.05
    MINITEST_FAIL_FAST_PATH = File.expand_path('minitest_fail_fast.rb', __dir__).freeze

    attr_reader :spec_file, :framework, :use_bundle_exec, :example_filters

    def initialize(spec_file, use_bundle_exec:, framework: nil, runner: :spawn, example_filters: [], worker_env_var: nil,
                   stop_on_first_failure: false)
      @spec_file = spec_file
      @framework = framework || self.class.detect_framework(spec_file)
      @use_bundle_exec = use_bundle_exec
      @runner = runner
      @example_filters = @framework == :rspec ? Array(example_filters) : []
      @worker_env_var = worker_env_var
      @stop_on_first_failure = stop_on_first_failure
    end

    def argv
      parts = [runner, *interpreter_args, spec_file, *filter_args, *fail_fast_args]
      @use_bundle_exec ? ['bundle', 'exec', *parts] : parts
    end

    def command
      cmd = ([runner, spec_file] + example_filters.flat_map { |f| ['-e', "'#{f}'"] }).join(' ')
      @use_bundle_exec ? "bundle exec #{cmd}" : cmd
    end

    def shell_command(timeout: nil, quiet: false)
      cmd = command
      cmd = "timeout #{timeout}s #{cmd}" if timeout
      cmd = "#{cmd} > /dev/null 2>&1" if quiet
      cmd
    end

    def run(timeout: nil, chdir: nil, capture: false, mirror_of: nil)
      if fork_execution?
        fork_runner = ForkRunner.acquire(use_bundle_exec: @use_bundle_exec, framework: @framework)
        if fork_runner
          return fork_runner.execute(
            spec_file,
            timeout: timeout,
            chdir: chdir || Dir.pwd,
            capture: capture,
            args: filter_args,
            stop_on_first_failure: @stop_on_first_failure,
            mirror_of: mirror_of,
            env: worker_env_overrides
          )
        end
      end

      return run_captured(timeout: timeout, chdir: chdir) if capture

      spawn_options = { pgroup: true, %i[out err] => File::NULL }
      spawn_options[:chdir] = chdir if chdir

      pid = Process.spawn(*spawn_argv, spawn_options)
      wait_with_deadline(pid, timeout)
    end

    def fork_execution?
      return false if @runner == :spawn

      ForkRunner.available?
    end

    def self.detect_framework(spec_file)
      FrameworkDetector.detect(spec_file)
    end

    def self.use_bundle_exec?(path)
      dir = File.dirname(File.expand_path(path))

      loop do
        return true if File.exist?(File.join(dir, 'Gemfile'))

        parent = File.dirname(dir)
        break if parent == dir

        dir = parent
      end

      false
    end

    private

    def spawn_argv
      overrides = worker_env_overrides
      overrides ? [overrides, *argv] : argv
    end

    def worker_env_overrides
      return nil unless @worker_env_var

      index = defined?(Parallel) && Parallel.respond_to?(:worker_number) ? Parallel.worker_number : nil
      { @worker_env_var => Configuration.worker_env_value(index) }
    end

    def runner
      @framework == :minitest ? 'ruby' : 'rspec'
    end

    def filter_args
      example_filters.flat_map { |filter| ['-e', filter] }
    end

    def interpreter_args
      return [] unless @stop_on_first_failure && @framework == :minitest

      ['-r', MINITEST_FAIL_FAST_PATH]
    end

    def fail_fast_args
      return [] unless @stop_on_first_failure && @framework == :rspec

      ['--fail-fast']
    end

    def run_captured(timeout:, chdir:)
      log = Tempfile.new(['mutation_tester_baseline', '.log'])
      spawn_options = { pgroup: true, %i[out err] => log.path }
      spawn_options[:chdir] = chdir if chdir

      pid = Process.spawn(*spawn_argv, spawn_options)
      result = wait_with_deadline(pid, timeout)
      result.output = File.read(log.path)
      result
    ensure
      log&.close
      log&.unlink
    end

    def wait_with_deadline(pid, timeout)
      unless timeout
        _pid, status = Process.waitpid2(pid)
        return Result.new(status.success?, false)
      end

      deadline = monotonic_time + timeout
      loop do
        _pid, status = Process.waitpid2(pid, Process::WNOHANG)
        return Result.new(status.success?, false) if status

        break if monotonic_time >= deadline

        sleep(POLL_INTERVAL)
      end

      _pid, status = Process.waitpid2(pid, Process::WNOHANG)
      return Result.new(status.success?, false) if status

      terminate_process_group(pid)
      Result.new(false, true)
    ensure
      terminate_process_group(pid) if pid && process_running?(pid)
    end

    def terminate_process_group(pid)
      Process.kill('KILL', -pid)
    rescue Errno::ESRCH
    ensure
      reap(pid)
    end

    def reap(pid)
      Process.waitpid(pid)
    rescue Errno::ECHILD, Errno::ESRCH
    end

    def process_running?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
