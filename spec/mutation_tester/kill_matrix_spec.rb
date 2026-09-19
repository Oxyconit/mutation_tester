require 'spec_helper'
require 'tmpdir'
require 'json'
require 'stringio'

RSpec.describe 'kill matrix' do
  let(:tmp_dir) { Dir.mktmpdir }
  let(:project_root) { File.join(tmp_dir, 'proj') }
  let(:source_file) { File.join(project_root, 'lib', 'calc.rb') }
  let(:original_source) do
    <<~RUBY
      class Calc
        def add(a, b)
          a + b
        end

        def double(a)
          a * 2
        end
      end
    RUBY
  end
  let(:mutations) do
    [
      { id: 1, type: :arithmetic, line: 3, method_name: :add, description: 'add broken',
        code: original_source.sub('a + b', 'a - b') },
      { id: 2, type: :arithmetic, line: 7, method_name: :double, description: 'double broken',
        code: original_source.sub('a * 2', 'a * 3') },
      { id: 3, type: :arithmetic, line: 3, method_name: :add, description: 'equivalent',
        code: original_source.sub('a + b', 'b + a') }
    ]
  end

  before do
    FileUtils.mkdir_p(File.join(project_root, 'lib'))
    FileUtils.mkdir_p(File.join(project_root, '.git'))
    File.write(source_file, original_source)
  end

  after do
    MutationTester::ForkRunner.shutdown_all
    FileUtils.remove_entry(tmp_dir)
  end

  def write_rspec_file
    path = File.join(project_root, 'spec', 'calc_spec.rb')
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, <<~RUBY)
      require_relative '../lib/calc'

      RSpec.describe Calc do
        describe '#add' do
          it('adds small numbers') { expect(Calc.new.add(1, 2)).to eq(3) }
          it('adds big numbers') { expect(Calc.new.add(10, 20)).to eq(30) }
        end

        describe '#double' do
          it('doubles') { expect(Calc.new.double(4)).to eq(8) }
        end

        it('sums a pair outside the add group') { expect(Calc.new.add(5, 5)).to eq(10) }
        it('builds a calc') { expect(Calc.new).to be_a(Calc) }
        xit('is skipped') { expect(Calc.new.add(1, 1)).to eq(2) }
      end
    RUBY
    path
  end

  def write_minitest_file
    path = File.join(project_root, 'test', 'calc_test.rb')
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, <<~RUBY)
      require 'minitest/autorun'
      require_relative '../lib/calc'

      class CalcTest < Minitest::Test
        def test_adds_small
          assert_equal 3, Calc.new.add(1, 2)
        end

        def test_adds_big
          assert_equal 30, Calc.new.add(10, 20)
        end

        def test_doubles
          assert_equal 8, Calc.new.double(4)
        end

        def test_builds_a_calc
          assert_kind_of Calc, Calc.new
        end

        def test_is_skipped
          skip 'not now'
        end
      end
    RUBY
    path
  end

  def write_test_file(framework)
    framework == :minitest ? write_minitest_file : write_rspec_file
  end

  def build_config(runner_mode, kill_matrix: true, parallel: 1)
    config = MutationTester::Configuration.new
    config.runner = runner_mode
    config.parallel_processes = parallel
    config.timeout = 30
    config.kill_matrix = kill_matrix
    config.show_progress = false
    config
  end

  def quietly
    original_stdout = $stdout
    original_stderr = $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new
    yield
  ensure
    $stdout = original_stdout
    $stderr = original_stderr
  end

  def run_mutants(test_file, config, muts = mutations)
    runner = MutationTester::MutationRunner.new(source_file, test_file, original_source, config)
    results = quietly { Dir.chdir(project_root) { runner.run(muts) } }
    results.sort_by { |result| result[:id] }
  end

  def expected_killers(framework)
    {
      rspec: [
        ['spec/calc_spec.rb[1:1:1]', 'spec/calc_spec.rb[1:1:2]', 'spec/calc_spec.rb[1:3]'],
        ['spec/calc_spec.rb[1:2:1]'],
        []
      ],
      minitest: [
        ['CalcTest#test_adds_big', 'CalcTest#test_adds_small'],
        ['CalcTest#test_doubles'],
        []
      ]
    }.fetch(framework)
  end

  %i[rspec minitest].each do |framework|
    %i[spawn fork in_memory].each do |runner_mode|
      it "lists every #{framework} test that fails under each mutant on the #{runner_mode} runner" do
        results = run_mutants(write_test_file(framework), build_config(runner_mode))

        expect(results.map { |r| r[:status] }).to eq(%i[killed killed survived])
        expect(results.map { |r| r[:killed_by] }).to eq(expected_killers(framework))
      end
    end

    it "reports the same #{framework} killers from parallel shadow workspaces as from a serial run" do
      results = run_mutants(write_test_file(framework), build_config(:fork, parallel: 2))

      expect(results.map { |r| r[:killed_by] }).to eq(expected_killers(framework))
    end

    it "keeps #{framework} results free of killer data when the mode is off" do
      results = run_mutants(write_test_file(framework), build_config(:spawn, kill_matrix: false))

      expect(results.map { |r| r[:status] }).to eq(%i[killed killed survived])
      expect(results).to all(satisfy { |r| !r.key?(:killed_by) })
    end

    it "reports no #{framework} killers for a mutant that times out" do
      config = build_config(:spawn)
      config.timeout = 2
      looping = [{ id: 1, type: :infinite, line: 3, description: 'loop',
                   code: original_source.sub('a + b', 'loop { }') }]

      results = run_mutants(write_test_file(framework), config, looping)

      expect(results.map { |r| r[:status] }).to eq([:timeout])
      expect(results.map { |r| r[:killed_by] }).to eq([[]])
    end

    it "reports a killed #{framework} mutant without killers when the mutated file no longer loads" do
      unloadable = [{ id: 1, type: :call_removal, line: 1, description: 'raises at load',
                      code: "raise 'broken at load'\n#{original_source}" }]

      results = run_mutants(write_test_file(framework), build_config(:spawn), unloadable)

      expect(results.map { |r| r[:status] }).to eq([:killed])
      expect(results.map { |r| r[:killed_by] }).to eq([[]])
    end
  end

  it 'records a killer list larger than a pipe buffer on the fork runner instead of timing out' do
    path = File.join(project_root, 'spec', 'calc_spec.rb')
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, <<~RUBY)
      require_relative '../lib/calc'

      RSpec.describe Calc do
        1500.times do |index|
          it("adds pair number \#{index} \#{'x' * 60}") { expect(Calc.new.add(index, 1)).to eq(index + 1) }
        end
      end
    RUBY

    results = run_mutants(path, build_config(:fork), [mutations.first])

    expect(results.map { |r| r[:status] }).to eq([:killed])
    expect(results.first[:killed_by].size).to eq(1500)
  end

  describe 'runs that cannot produce a trustworthy matrix' do
    def run_core_capturing(test_file, config)
      core = MutationTester::Core.new(source_file, test_file, config)
      output = StringIO.new
      original_stdout = $stdout
      $stdout = output
      passed = quietly_stderr { Dir.chdir(project_root) { core.run } }
      [passed, output.string, core]
    ensure
      $stdout = original_stdout
    end

    def quietly_stderr
      original_stderr = $stderr
      $stderr = StringIO.new
      yield
    ensure
      $stderr = original_stderr
    end

    def audit_config(runner_mode)
      config = build_config(runner_mode)
      config.reporters = []
      config
    end

    it 'aborts before any mutant runs when a minitest plugin drops the recorder, instead of reporting an empty matrix' do
      path = write_minitest_file
      File.write(path, File.read(path) + <<~RUBY)

        module Minitest
          def self.plugin_zz_replace_reporters_init(_options)
            reporter.reporters.clear
          end
        end
        Minitest.register_plugin(:zz_replace_reporters)
      RUBY

      passed, output, core = run_core_capturing(path, audit_config(:spawn))

      expect(passed).to be(false)
      expect(output).to include('could not record a single test')
      expect(core.mutations).to be_empty
      expect(core.results).to be_empty
    end

    it 'aborts the same way for an rspec file whose baseline passes without a single example' do
      path = File.join(project_root, 'spec', 'calc_spec.rb')
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "require_relative '../lib/calc'\n\nRSpec.describe(Calc) {}\n")

      passed, output, core = run_core_capturing(path, audit_config(:fork))

      expect(passed).to be(false)
      expect(output).to include('could not record a single test')
      expect(core.results).to be_empty
    end

    it 'refuses fail_fast set through the configuration before the baseline runs, because the matrix would be partial' do
      config = audit_config(:spawn)
      config.fail_fast = true
      expect(MutationTester::TestCommand).not_to receive(:new)

      passed, output, core = run_core_capturing(write_rspec_file, config)

      expect(passed).to be(false)
      expect(output).to include('kill_matrix cannot be combined with fail_fast')
      expect(core.results).to be_empty
    end
  end

  describe 'the JSON report of a full run' do
    def run_core(test_file, kill_matrix:)
      config = build_config(:fork, kill_matrix: kill_matrix)
      config.reporters = [:json]
      config.output_dir = File.join(tmp_dir, 'reports')
      config.fail_on_threshold = false
      core = MutationTester::Core.new(source_file, test_file, config)
      quietly { Dir.chdir(project_root) { core.run } }
      JSON.parse(File.read(File.join(config.output_dir, 'mutation_report.json')))
    end

    it 'lists every rspec test of the baseline run, so a test that kills nothing stays visible' do
      report = run_core(write_rspec_file, kill_matrix: true)

      expect(report['kill_matrix']).to be(true)
      expect(report['tests']).to eq([
        { 'id' => 'spec/calc_spec.rb[1:1:1]', 'name' => 'Calc#add adds small numbers', 'line' => 5, 'status' => 'passed' },
        { 'id' => 'spec/calc_spec.rb[1:1:2]', 'name' => 'Calc#add adds big numbers', 'line' => 6, 'status' => 'passed' },
        { 'id' => 'spec/calc_spec.rb[1:2:1]', 'name' => 'Calc#double doubles', 'line' => 10, 'status' => 'passed' },
        { 'id' => 'spec/calc_spec.rb[1:3]', 'name' => 'Calc sums a pair outside the add group', 'line' => 13, 'status' => 'passed' },
        { 'id' => 'spec/calc_spec.rb[1:4]', 'name' => 'Calc builds a calc', 'line' => 14, 'status' => 'passed' },
        { 'id' => 'spec/calc_spec.rb[1:5]', 'name' => 'Calc is skipped', 'line' => 15, 'status' => 'skipped' }
      ])
      killers = report['mutations'].flat_map { |mutation| mutation['killed_by'] }.uniq
      expect(killers).not_to include('spec/calc_spec.rb[1:4]')
      expect(report['tests'].map { |test| test['id'] }).to include(*killers)
    end

    it 'lists every minitest test of the baseline run with its status' do
      report = run_core(write_minitest_file, kill_matrix: true)

      expect(report['kill_matrix']).to be(true)
      expect(report['tests'].map { |test| test.values_at('id', 'line', 'status') }).to eq([
        ['CalcTest#test_adds_small', 5, 'passed'],
        ['CalcTest#test_adds_big', 9, 'passed'],
        ['CalcTest#test_doubles', 13, 'passed'],
        ['CalcTest#test_builds_a_calc', 17, 'passed'],
        ['CalcTest#test_is_skipped', 21, 'skipped']
      ])
      killers = report['mutations'].flat_map { |mutation| mutation['killed_by'] }.uniq
      expect(killers).to contain_exactly('CalcTest#test_adds_small', 'CalcTest#test_adds_big', 'CalcTest#test_doubles')
    end

    it 'adds no kill matrix fields to the report when the mode is off' do
      report = run_core(write_rspec_file, kill_matrix: false)

      expect(report.keys).to contain_exactly('schema_version', 'interrupted', 'metadata', 'summary', 'mutations')
      expect(report['mutations']).to all(satisfy { |mutation| !mutation.key?('killed_by') })
    end
  end
end
