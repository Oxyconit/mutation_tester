require 'spec_helper'
require 'rake'
require 'tmpdir'
require 'mutation_tester/rake_task'
require_relative 'support/bench_pricer_fixture'

RSpec.describe 'bench rake tasks' do
  before do
    @original_application = Rake.application
    Rake.application = Rake::Application.new
    MutationTester.instance_variable_set(:@rake_tasks_loaded, false)
    MutationTester.load_rake_tasks
  end

  after do
    Rake.application = @original_application
  end

  describe 'non-Rails entrypoint' do
    it 'defines the bench:rerun task' do
      expect(Rake::Task.task_defined?('bench:rerun')).to be(true)
    end

    it 'does not define the task twice when the loader runs more than once' do
      MutationTester.load_rake_tasks

      expect(Rake::Task['bench:rerun'].actions.size).to eq(1)
    end
  end

  describe 'benchmark definitions' do
    let(:definitions) { MutationTester::Bench.definitions.to_h { |definition| [definition[:name], definition] } }

    it 'covers the weak pricer, the weak calculator and the complete calculator' do
      expect(definitions.keys).to eq(%w[pricer_weak calculator_weak calculator_complete])
    end

    it 'reuses the imported benchmark A pricer data instead of duplicating its source' do
      expect(definitions['pricer_weak'][:files]['lib/basket/pricer.rb']).to eq(BenchPricerFixture::SOURCE)
      expect(definitions['pricer_weak'][:files]['spec/basket/pricer_spec.rb']).to eq(BenchPricerFixture::WEAK_SPEC)
      expect(definitions['pricer_weak'][:files]['spec/spec_helper.rb']).to eq(BenchPricerFixture::SPEC_HELPER)
    end

    it 'reuses the calculator example files instead of duplicating them' do
      calculator = File.read(File.expand_path('../examples/calculator.rb', __dir__))

      expect(definitions['calculator_weak'][:files]['calculator.rb']).to eq(calculator)
      expect(definitions['calculator_weak'][:files]['calculator_spec.rb'])
        .to eq(File.read(File.expand_path('../examples/calculator_spec.rb', __dir__)))
      expect(definitions['calculator_complete'][:files]['calculator.rb']).to eq(calculator)
      expect(definitions['calculator_complete'][:files]['calculator_100_perc_spec.rb'])
        .to eq(File.read(File.expand_path('../examples/calculator_100_perc_spec.rb', __dir__)))
    end
  end

  describe 'project builder' do
    it 'writes the benchmark files and marks the project root with a git repository' do
      definition = MutationTester::Bench.definitions.first

      Dir.mktmpdir do |dir|
        MutationTester::Bench.build_project(definition, dir)

        expect(File.read(File.join(dir, 'lib/basket/pricer.rb'))).to eq(BenchPricerFixture::SOURCE)
        expect(File.read(File.join(dir, 'spec/basket/pricer_spec.rb'))).to eq(BenchPricerFixture::WEAK_SPEC)
        expect(File.directory?(File.join(dir, '.git'))).to be(true)
      end
    end
  end

  describe 'survivor normalization' do
    let(:results) do
      [
        { line: 33, type: :number, original: '0', mutated: '1', status: :survived },
        { line: 21, type: :number, original: '0', mutated: '1', status: :survived },
        { line: 33, type: :comparison, original: '<', mutated: '<=', status: :survived },
        { line: 24, type: :logical, original: nil, mutated: nil, status: :survived },
        { line: 5, type: :string, original: 'a', mutated: 'b', status: :killed }
      ]
    end

    it 'renders only survivors as line|type|original|mutated tuples' do
      expect(MutationTester::Bench.normalized_survivors(results)).to eq(
        ['21|number|0|1', '24|logical||', '33|comparison|<|<=', '33|number|0|1']
      )
    end

    it 'sorts the tuples deterministically so two reruns can be diffed' do
      expect(MutationTester::Bench.normalized_survivors(results.reverse))
        .to eq(MutationTester::Bench.normalized_survivors(results))
    end
  end

  describe 'summary markdown' do
    let(:runs) do
      [
        {
          name: 'alpha',
          description: 'first benchmark',
          wall_seconds: 1.234,
          results: [
            { line: 12, type: :comparison, original: '>=', mutated: '>', status: :survived },
            { line: 3, type: :number, original: '1', mutated: '2', status: :killed },
            { line: 4, type: :string, original: 'a', mutated: 'b', status: :timeout },
            { line: 5, type: :number, original: '1', mutated: '0', status: :stillborn },
            { line: 6, type: :number, original: '2', mutated: '3', status: :error }
          ]
        },
        {
          name: 'beta',
          description: 'second benchmark',
          wall_seconds: 0.5,
          results: [{ line: 1, type: :number, original: '1', mutated: '2', status: :killed }]
        }
      ]
    end

    let(:markdown) { MutationTester::Bench.summary_markdown(runs) }

    it 'reports the full status taxonomy, the score excluding stillborn and error, and the wall time' do
      expect(markdown).to include('| alpha | 5 | 1 | 1 | 1 | 1 | 1 | 66.67 | 1.23 |')
      expect(markdown).to include('| beta | 1 | 1 | 0 | 0 | 0 | 0 | 100.00 | 0.50 |')
    end

    it 'pins the reference values from the latest rerun report as documentation' do
      expect(markdown).to include('| pricer_weak | 106 | 26 | 75.47 |')
      expect(markdown).to include('| calculator_weak | 57 | 5 | 91.23 |')
      expect(markdown).to include('| calculator_complete | 57 | 0 | 100.00 |')
    end

    it 'lists the normalized survivors per benchmark and marks survivor-free benchmarks' do
      expect(markdown).to include("## Survivors: alpha\n\n```\n12|comparison|>=|>\n```")
      expect(markdown).to include("## Survivors: beta\n\nnone")
    end
  end
end
