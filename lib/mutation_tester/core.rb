require_relative 'progress_display'

module MutationTester
  class Core
    attr_reader :source_file, :spec_file, :mutations, :results, :config

    def initialize(source_file, spec_file, config = MutationTester.configuration)
      @source_file = File.expand_path(source_file)
      @spec_file = File.expand_path(spec_file)
      @config = config
      @mutations = []
      @results = []
      @parse_failed = false
      @shadow_aborted = false
      MutationRunner.recover_in_place_backup(@source_file)
      @original_content = File.read(@source_file)
    end

    def run
      print_header
      return false unless run_original_tests

      generate_mutations
      return false if @parse_failed

      if @mutations.empty?
        puts Rainbow("\n✓ No mutations were generated for this file; nothing to test.").green
        return true
      end

      unless shadow_environment_reliable?
        @shadow_aborted = true
        return false
      end

      run_mutations
      generate_reports
      return report_interruption if interrupted?
      return report_infrastructure_failure if infrastructure_failure?

      check_threshold
    ensure
      @mutation_runner&.cleanup_shadow_workspaces
      ForkRunner.shutdown_all
    end

    def interrupted?
      @config.fail_fast &&
        @results.size < @mutations.size &&
        @results.any? { |result| result[:status] == :survived }
    end

    def mutation_score
      Reporters::BaseReporter.score(@results, policy: @config.timeout_policy)
    end

    def infrastructure_failure?
      @shadow_aborted || (!@results.empty? && scored_count.zero?)
    end

    def threshold_met?
      return true unless @config.fail_on_threshold

      mutation_score >= @config.minimum_score
    end

    private

    def print_header
      puts Rainbow('=' * 80).bright
      puts Rainbow("🧬 MutationTester v#{MutationTester::VERSION}").bright.cyan
      puts Rainbow('=' * 80).bright
      puts "Source: #{@source_file}"
      puts "Spec:   #{@spec_file}"
      puts Rainbow('=' * 80).bright
    end

    def run_original_tests
      puts Rainbow("\n🧪 Running original tests...").yellow
      command = test_command
      baseline_started = monotonic_time
      result = command.run(timeout: @config.baseline_timeout, capture: true)
      baseline_elapsed = monotonic_time - baseline_started

      if result.timed_out?
        puts Rainbow("❌ Original tests exceeded the baseline deadline of #{@config.baseline_timeout}s and were terminated.").red
        puts Rainbow('   Speed them up or raise config.baseline_timeout (nil disables the deadline).').red
        return false
      end

      unless result.passed?
        replay_baseline_output(result.output)
        puts Rainbow('❌ Original tests are failing. Fix them first!').red
        puts Rainbow("\nDebug: The following command failed:").yellow
        puts Rainbow("  #{command.command}").cyan
        return false
      end
      puts Rainbow('✓ Original tests passed').green
      @config.baseline_duration = baseline_elapsed
      true
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def replay_baseline_output(output)
      return if output.nil? || output.strip.empty?

      puts Rainbow("\n🔴 Original test output:").red
      puts output
    end

    def generate_mutations
      puts Rainbow("\n📝 Generating mutations...").yellow

      ast = Parser::CurrentRuby.parse(@original_content)
      mutator = Mutator.new(@source_file, @config)
      @mutations = mutator.generate_mutations(ast)

      puts Rainbow("✓ Generated #{@mutations.size} mutations").green
    rescue Parser::SyntaxError => e
      puts Rainbow("❌ Failed to parse source file: #{e.message}").red
      @parse_failed = true
      @mutations = []
    end

    def shadow_environment_reliable?
      return true unless @config.parallel_processes > 1
      return true if mutation_runner.in_memory_first?

      puts Rainbow("\n🩺 Verifying the shadow workspace with the unmutated source...").yellow
      if mutation_runner.shadow_baseline_passes?
        puts Rainbow('✓ Shadow workspace verified with the unmutated source').green
        return true
      end

      puts Rainbow('❌ The unmutated source fails inside the shadow workspace; the shadow environment is unreliable.').red
      puts Rainbow('   Every mutant would falsely die there, so the run is aborted instead of reporting a misleading score.').red
      false
    end

    def run_mutations
      return if @mutations.empty?

      puts Rainbow("\n🔬 Running mutations in #{@config.parallel_processes} parallel job#{"s" if @config.parallel_processes > 1}...").yellow

      progress_display = ProgressDisplay.new(@mutations.size, @config)

      @results = mutation_runner.run(@mutations) do |mutation, index|
        progress_display.update(mutation, index)
      end

      progress_display.finish
      puts Rainbow("✓ Completed #{@results.size} mutations").green
    end

    def mutation_runner
      @mutation_runner ||= MutationRunner.new(@source_file, @spec_file, @original_content, @config)
    end

    def generate_reports
      puts Rainbow("\n📊 Generating reports...").yellow
      FileUtils.mkdir_p(@config.output_dir)

      @config.reporters.each do |reporter_type|
        reporter = create_reporter(reporter_type)
        reporter.generate if reporter
      end
    end

    def create_reporter(type)
      case type
      when :console
        Reporters::ConsoleReporter.new(@results, @source_file, @spec_file, @config, interrupted: interrupted?)
      when :html
        Reporters::HtmlReporter.new(@results, @source_file, @spec_file, @config, interrupted: interrupted?)
      when :json
        Reporters::JsonReporter.new(@results, @source_file, @spec_file, @config, interrupted: interrupted?)
      end
    end

    def test_command
      TestCommand.new(
        @spec_file,
        use_bundle_exec: TestCommand.use_bundle_exec?(@source_file),
        runner: @config.runner
      )
    end

    def report_interruption
      puts Rainbow("\n🛑 Run interrupted by --fail-fast: a mutant survived after #{@results.size} of #{@mutations.size} mutations.").red
      puts Rainbow('   Reports contain the results obtained up to the interruption.').red
      false
    end

    def scored_count
      @results.count { |r| %i[killed timeout survived].include?(Reporters::BaseReporter.status_for(r)) }
    end

    def status_count(status)
      @results.count { |r| Reporters::BaseReporter.status_for(r) == status }
    end

    def report_infrastructure_failure
      puts Rainbow("\n❌ Run failed: none of the #{@results.size} mutants could be scored (#{status_count(:error)} error, #{status_count(:stillborn)} stillborn).").red
      puts Rainbow('   This indicates an infrastructure or runner problem (test environment, workspace, or test command), not a test-quality gap.').red
      false
    end

    def check_threshold
      score = mutation_score

      unless threshold_met?
        puts Rainbow("\n❌ Mutation score #{score}% is below threshold #{@config.minimum_score}%").red
        return false
      end

      puts Rainbow("\n✓ Mutation score: #{score}%").green
      true
    end
  end
end
