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
