require 'spec_helper'

RSpec.describe MutationTester::Configuration do
  around do |example|
    saved = ENV['MUTATION_TESTER_PARALLEL_PROCESSES']
    ENV.delete('MUTATION_TESTER_PARALLEL_PROCESSES')
    example.run
  ensure
    if saved.nil?
      ENV.delete('MUTATION_TESTER_PARALLEL_PROCESSES')
    else
      ENV['MUTATION_TESTER_PARALLEL_PROCESSES'] = saved
    end
  end

  describe 'default values' do
    subject(:config) { described_class.new }

    it 'uses the documented per-mutant and baseline timeouts' do
      expect(config.timeout).to eq(30)
      expect(config.baseline_timeout).to eq(300)
    end

    it 'enables the console, html and json reporters by default' do
      expect(config.reporters).to eq(%i[console html json])
    end

    it 'writes reports under tmp/mutation_reports by default' do
      expect(config.output_dir).to eq('tmp/mutation_reports')
    end

    it 'defaults the quality threshold and its enforcement' do
      expect(config.minimum_score).to eq(80.0)
      expect(config.fail_on_threshold).to be(true)
    end

    it 'shows the file path and progress by default' do
      expect(config.show_file_path).to be(true)
      expect(config.show_progress).to be(true)
    end

    it 'enables every mutation type by default except the opt-in strict equality mode' do
      expect(config.mutation_types).to eq(
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
      )
      expect(config.mutation_types[:strict_equality]).to be(false)
      expect(config.mutation_types.reject { |_type, enabled| enabled }.keys).to eq([:strict_equality])
    end
  end

  describe '.auto_parallel_processes' do
    it 'uses the machine core count when it is below the cap' do
      allow(Etc).to receive(:nprocessors).and_return(4)

      expect(described_class.auto_parallel_processes).to eq(4)
    end

    it 'caps the derived value on machines with many cores' do
      allow(Etc).to receive(:nprocessors).and_return(32)

      expect(described_class.auto_parallel_processes).to eq(described_class::AUTO_PARALLEL_CAP)
    end

    it 'never derives a value below one' do
      allow(Etc).to receive(:nprocessors).and_return(0)

      expect(described_class.auto_parallel_processes).to eq(1)
    end
  end

  describe '#parallel_processes default and overrides' do
    it 'defaults to the auto-derived core count' do
      allow(Etc).to receive(:nprocessors).and_return(6)

      expect(described_class.new.parallel_processes).to eq(6)
    end

    it 'lets the environment variable win over the auto default' do
      allow(Etc).to receive(:nprocessors).and_return(6)
      ENV['MUTATION_TESTER_PARALLEL_PROCESSES'] = '2'

      expect(described_class.new.parallel_processes).to eq(2)
    end

    it 'lets an explicit assignment force serial execution' do
      config = described_class.new
      config.parallel_processes = 1

      expect(config.parallel_processes).to eq(1)
    end

    it 'keeps the setter validation for values below one' do
      config = described_class.new

      expect { config.parallel_processes = 0 }
        .to output(/parallel_processes must be >= 1/).to_stderr
      expect(config.parallel_processes).to eq(1)
    end
  end

  describe '#runner' do
    around do |example|
      saved = ENV['MUTATION_TESTER_RUNNER']
      ENV.delete('MUTATION_TESTER_RUNNER')
      example.run
    ensure
      if saved.nil?
        ENV.delete('MUTATION_TESTER_RUNNER')
      else
        ENV['MUTATION_TESTER_RUNNER'] = saved
      end
    end

    it 'defaults to auto' do
      expect(described_class.new.runner).to eq(:auto)
    end

    it 'accepts fork, spawn and in_memory given as strings or symbols' do
      config = described_class.new

      config.runner = 'fork'
      expect(config.runner).to eq(:fork)

      config.runner = :spawn
      expect(config.runner).to eq(:spawn)

      config.runner = 'in_memory'
      expect(config.runner).to eq(:in_memory)
    end

    it 'falls back to auto with a warning for an unknown value' do
      config = described_class.new

      expect { config.runner = 'turbo' }
        .to output(/runner must be one of auto, fork, spawn/).to_stderr

      expect(config.runner).to eq(:auto)
    end

    it 'reads the runner from the environment' do
      ENV['MUTATION_TESTER_RUNNER'] = 'spawn'

      expect(described_class.new.runner).to eq(:spawn)
    end

    it 'survives a merge round trip' do
      config = described_class.new
      merged = config.merge(runner: :spawn)

      expect(merged.runner).to eq(:spawn)
      expect(config.runner).to eq(:auto)
    end
  end

  describe '#worker_env_var' do
    around do |example|
      saved = ENV['MUTATION_TESTER_WORKER_ENV']
      ENV.delete('MUTATION_TESTER_WORKER_ENV')
      example.run
    ensure
      if saved.nil?
        ENV.delete('MUTATION_TESTER_WORKER_ENV')
      else
        ENV['MUTATION_TESTER_WORKER_ENV'] = saved
      end
    end

    it 'defaults to nil so the feature stays off' do
      expect(described_class.new.worker_env_var).to be_nil
    end

    it 'reads the default from MUTATION_TESTER_WORKER_ENV' do
      ENV['MUTATION_TESTER_WORKER_ENV'] = 'TEST_ENV_NUMBER'

      expect(described_class.new.worker_env_var).to eq('TEST_ENV_NUMBER')
    end

    it 'normalizes a blank or whitespace value to nil' do
      config = described_class.new
      config.worker_env_var = '   '

      expect(config.worker_env_var).to be_nil
    end

    it 'survives a merge round trip without leaking back to the source' do
      config = described_class.new
      merged = config.merge(worker_env_var: 'TEST_ENV_NUMBER')

      expect(merged.worker_env_var).to eq('TEST_ENV_NUMBER')
      expect(config.worker_env_var).to be_nil
    end
  end

  describe '#after_fork_file' do
    around do |example|
      saved = ENV['MUTATION_TESTER_AFTER_FORK']
      ENV.delete('MUTATION_TESTER_AFTER_FORK')
      example.run
    ensure
      if saved.nil?
        ENV.delete('MUTATION_TESTER_AFTER_FORK')
      else
        ENV['MUTATION_TESTER_AFTER_FORK'] = saved
      end
    end

    it 'defaults to nil so the feature stays off' do
      expect(described_class.new.after_fork_file).to be_nil
    end

    it 'reads the default from MUTATION_TESTER_AFTER_FORK' do
      ENV['MUTATION_TESTER_AFTER_FORK'] = 'db/after_fork.rb'

      expect(described_class.new.after_fork_file).to eq(File.expand_path('db/after_fork.rb'))
    end

    it 'normalizes a blank or whitespace value to nil' do
      config = described_class.new
      config.after_fork_file = '   '

      expect(config.after_fork_file).to be_nil
    end

    it 'expands a relative path so forked clones resolve it regardless of their working directory' do
      config = described_class.new
      config.after_fork_file = 'db/after_fork.rb'

      expect(config.after_fork_file).to eq(File.expand_path('db/after_fork.rb'))
    end

    it 'survives a merge round trip without leaking back to the source' do
      config = described_class.new
      merged = config.merge(after_fork_file: '/tmp/after_fork.rb')

      expect(merged.after_fork_file).to eq('/tmp/after_fork.rb')
      expect(config.after_fork_file).to be_nil
    end
  end

  describe '.worker_env_value' do
    it 'follows the parallel_tests TEST_ENV_NUMBER convention' do
      expect(described_class.worker_env_value(0)).to eq('')
      expect(described_class.worker_env_value(1)).to eq('2')
      expect(described_class.worker_env_value(2)).to eq('3')
    end

    it 'treats a nil or negative worker index as the first worker' do
      expect(described_class.worker_env_value(nil)).to eq('')
      expect(described_class.worker_env_value(-1)).to eq('')
    end
  end

  describe '#worker_env_assignment' do
    it 'returns nil when no worker-env var is configured' do
      expect(described_class.new.worker_env_assignment(1)).to be_nil
    end

    it 'maps the configured var to the per-worker value' do
      config = described_class.new
      config.worker_env_var = 'TEST_ENV_NUMBER'

      expect(config.worker_env_assignment(0)).to eq('TEST_ENV_NUMBER' => '')
      expect(config.worker_env_assignment(1)).to eq('TEST_ENV_NUMBER' => '2')
    end
  end

  describe '#timeout_factor' do
    it 'defaults to 5' do
      expect(described_class.new.timeout_factor).to eq(5)
    end

    it 'accepts a positive numeric value, including a numeric string' do
      config = described_class.new

      config.timeout_factor = 2.5
      expect(config.timeout_factor).to eq(2.5)

      config.timeout_factor = '3'
      expect(config.timeout_factor).to eq(3.0)
    end

    it 'falls back to the default with a warning for zero, negative, or unparseable values' do
      config = described_class.new

      expect { config.timeout_factor = 0 }
        .to output(/timeout_factor must be a number greater than 0/).to_stderr
      expect(config.timeout_factor).to eq(5)

      expect { config.timeout_factor = 'abc' }
        .to output(/timeout_factor must be a number greater than 0/).to_stderr
      expect(config.timeout_factor).to eq(5)

      expect { config.timeout_factor = -1 }
        .to output(/timeout_factor must be a number greater than 0/).to_stderr
      expect(config.timeout_factor).to eq(5)
    end

    it 'survives a merge round trip without leaking back to the source' do
      config = described_class.new
      merged = config.merge(timeout_factor: 2)

      expect(merged.timeout_factor).to eq(2.0)
      expect(config.timeout_factor).to eq(5)
    end
  end

  describe '#timeout_policy' do
    it 'defaults to killed so timeouts keep counting as kills' do
      expect(described_class.new.timeout_policy).to eq(:killed)
    end

    it 'accepts killed and separate given as strings or symbols' do
      config = described_class.new

      config.timeout_policy = 'separate'
      expect(config.timeout_policy).to eq(:separate)

      config.timeout_policy = :killed
      expect(config.timeout_policy).to eq(:killed)
    end

    it 'falls back to killed with a warning for an unknown value' do
      config = described_class.new

      expect { config.timeout_policy = 'lenient' }
        .to output(/timeout_policy must be one of killed, separate/).to_stderr

      expect(config.timeout_policy).to eq(:killed)
    end

    it 'survives a merge round trip without leaking back to the source' do
      config = described_class.new
      merged = config.merge(timeout_policy: :separate)

      expect(merged.timeout_policy).to eq(:separate)
      expect(config.timeout_policy).to eq(:killed)
    end
  end

  describe '#effective_timeout (baseline-calibrated per-mutant deadline)' do
    it 'keeps the fixed 30s default when no baseline duration was measured' do
      expect(described_class.new.effective_timeout).to eq(30)
    end

    it 'scales the measured baseline duration by the timeout factor' do
      config = described_class.new
      config.baseline_duration = 10

      expect(config.effective_timeout).to eq(50)
    end

    it 'never drops below the floor for an ultra-fast baseline' do
      config = described_class.new
      config.baseline_duration = 0.2

      expect(config.effective_timeout).to eq(described_class::CALIBRATED_TIMEOUT_FLOOR)
    end

    it 'uses an overridden factor for the calibration' do
      config = described_class.new
      config.timeout_factor = 2
      config.baseline_duration = 10

      expect(config.effective_timeout).to eq(20)
    end

    it 'keeps a fixed budget and disables calibration when timeout is set explicitly' do
      config = described_class.new
      config.timeout = 12
      config.baseline_duration = 100

      expect(config.effective_timeout).to eq(12)
    end

    it 'keeps an explicit nil timeout as no deadline even with a measured baseline' do
      config = described_class.new
      config.timeout = nil
      config.baseline_duration = 100

      expect(config.effective_timeout).to be_nil
    end

    it 'treats a timeout set through merge as explicit' do
      merged = described_class.new.merge(timeout: 45)
      merged.baseline_duration = 100

      expect(merged.effective_timeout).to eq(45)
    end

    it 'carries the explicit flag across the per-run copy from merge' do
      config = described_class.new
      config.timeout = 60
      merged = config.merge({})
      merged.baseline_duration = 100

      expect(merged.effective_timeout).to eq(60)
      expect(merged.timeout_explicitly_set?).to be(true)
    end

    it 'keeps calibration active on a per-run copy of an untouched timeout' do
      merged = described_class.new.merge({})
      merged.baseline_duration = 10

      expect(merged.timeout_explicitly_set?).to be(false)
      expect(merged.effective_timeout).to eq(50)
    end
  end

  describe '#merge isolation (deep copy of mutable collections)' do
    it 'does not leak an in-place mutation of the copy back into the source' do
      config = described_class.new
      merged = config.merge({})

      merged.mutation_types[:string] = false
      merged.reporters << :custom

      expect(config.mutation_types[:string]).to be(true)
      expect(config.reporters).to eq(%i[console html json])
    end

    it 'does not leak an in-place mutation of the source into an existing copy' do
      config = described_class.new
      merged = config.merge({})

      config.mutation_types[:arithmetic] = false
      config.reporters.clear

      expect(merged.mutation_types[:arithmetic]).to be(true)
      expect(merged.reporters).to eq(%i[console html json])
    end

    it 'gives the copy distinct collection objects' do
      config = described_class.new
      merged = config.merge({})

      expect(merged.mutation_types).not_to equal(config.mutation_types)
      expect(merged.reporters).not_to equal(config.reporters)
    end
  end

  describe '#merge option handling' do
    it 'ignores an unknown option key without raising and applies the known ones' do
      config = described_class.new

      merged = nil
      expect { merged = config.merge(nonexistent_option: 123, minimum_score: 55.0) }
        .not_to raise_error

      expect(merged.minimum_score).to eq(55.0)
      expect(merged.reporters).to eq(%i[console html json])
      expect(config.minimum_score).to eq(80.0)
    end
  end
end
