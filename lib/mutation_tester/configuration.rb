require 'etc'

module MutationTester
  class Configuration
    RUNNER_MODES = %i[auto fork spawn in_memory].freeze
    AUTO_PARALLEL_CAP = 8

    def self.auto_parallel_processes
      [[Etc.nprocessors, AUTO_PARALLEL_CAP].min, 1].max
    end

    attr_reader :parallel_processes, :runner

    attr_accessor :timeout,
      :baseline_timeout,
      :mutation_types,
      :reporters,
      :output_dir,
      :minimum_score,
      :fail_on_threshold,
      :verbose,
      :show_file_path,
      :show_progress,
      :test_selection,
      :fail_fast

    def initialize
      self.parallel_processes = ENV['MUTATION_TESTER_PARALLEL_PROCESSES'] || self.class.auto_parallel_processes
      self.runner = ENV['MUTATION_TESTER_RUNNER'] || :auto
      @timeout = 30
      @baseline_timeout = 300
      @mutation_types = {
        arithmetic: true,
        comparison: true,
        logical: true,
        boolean: true,
        number: true,
        string: true,
        conditional: true,
        call_removal: true,
        nil_injection: true,
        argument: true,
        strict_equality: false
      }
      @reporters = %i[console html json]
      @output_dir = 'tmp/mutation_reports'
      @minimum_score = 80.0
      @fail_on_threshold = true
      @verbose = false
      @show_file_path = true
      @show_progress = true
      @test_selection = true
      @fail_fast = false
    end

    def merge(options)
      config = dup
      options.each do |key, value|
        config.public_send("#{key}=", value) if config.respond_to?("#{key}=")
      end
      config
    end

    def initialize_copy(source)
      super
      @mutation_types = source.mutation_types.dup
      @reporters = source.reporters.dup
    end

    def parallel_processes=(value)
      count = value.to_i
      if count < 1
        warn "[MutationTester] parallel_processes must be >= 1; got #{value.inspect}, falling back to 1 (serial execution)."
        count = 1
      end
      @parallel_processes = count
    end

    def runner=(value)
      mode = value.to_s.strip.downcase.to_sym
      unless RUNNER_MODES.include?(mode)
        warn "[MutationTester] runner must be one of #{RUNNER_MODES.join(", ")}; got #{value.inspect}, falling back to auto."
        mode = :auto
      end
      @runner = mode
    end
  end
end
