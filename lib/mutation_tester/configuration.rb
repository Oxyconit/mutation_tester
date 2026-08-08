require 'etc'

module MutationTester
  class Configuration
    RUNNER_MODES = %i[auto fork spawn in_memory].freeze
    TIMEOUT_POLICIES = %i[killed separate].freeze
    AUTO_PARALLEL_CAP = 8
    DEFAULT_MINIMUM_SCORE = 80.0
    DEFAULT_TIMEOUT = 30
    DEFAULT_TIMEOUT_FACTOR = 5
    CALIBRATED_TIMEOUT_FLOOR = 5

    def self.auto_parallel_processes
      [[Etc.nprocessors, AUTO_PARALLEL_CAP].min, 1].max
    end

    def self.worker_env_value(index)
      number = index.to_i
      number <= 0 ? '' : (number + 1).to_s
    end

    attr_reader :parallel_processes, :runner, :worker_env_var, :after_fork_file, :timeout, :timeout_factor,
      :timeout_policy

    attr_accessor :baseline_duration,
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
      self.worker_env_var = ENV['MUTATION_TESTER_WORKER_ENV']
      self.after_fork_file = ENV['MUTATION_TESTER_AFTER_FORK']
      @timeout = DEFAULT_TIMEOUT
      @timeout_factor = DEFAULT_TIMEOUT_FACTOR
      @timeout_policy = :killed
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
      @minimum_score = DEFAULT_MINIMUM_SCORE
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

    def timeout=(value)
      @timeout_explicit = true
      @timeout = value
    end

    def timeout_explicitly_set?
      !!@timeout_explicit
    end

    def timeout_factor=(value)
      factor = coerce_numeric(value)
      unless factor.positive?
        warn "[MutationTester] timeout_factor must be a number greater than 0; got #{value.inspect}, falling back to #{DEFAULT_TIMEOUT_FACTOR}."
        factor = DEFAULT_TIMEOUT_FACTOR
      end
      @timeout_factor = factor
    end

    def timeout_policy=(value)
      policy = value.to_s.strip.downcase.to_sym
      unless TIMEOUT_POLICIES.include?(policy)
        warn "[MutationTester] timeout_policy must be one of #{TIMEOUT_POLICIES.join(", ")}; got #{value.inspect}, falling back to killed."
        policy = :killed
      end
      @timeout_policy = policy
    end

    def effective_timeout
      return @timeout if timeout_explicitly_set? || @baseline_duration.nil?

      [CALIBRATED_TIMEOUT_FLOOR, @timeout_factor * @baseline_duration].max
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

    def worker_env_var=(value)
      normalized = value.to_s.strip
      @worker_env_var = normalized.empty? ? nil : normalized
    end

    def after_fork_file=(value)
      normalized = value.to_s.strip
      @after_fork_file = normalized.empty? ? nil : File.expand_path(normalized)
    end

    def worker_env_assignment(index)
      return nil unless @worker_env_var

      { @worker_env_var => self.class.worker_env_value(index) }
    end

    private

    def coerce_numeric(value)
      Float(value)
    rescue ArgumentError, TypeError
      0
    end
  end
end
