require 'spec_helper'
require 'tmpdir'
require 'stringio'
require 'rbconfig'

RSpec.describe 'minitest preloads leave the choice of the minitest version to the test file' do
  let(:tmp_dir) { Dir.mktmpdir }
  let(:project_root) { File.join(tmp_dir, 'proj') }
  let(:source_file) { File.join(project_root, 'lib', 'calc.rb') }
  let(:test_file) { File.join(project_root, 'test', 'calc_test.rb') }
  let(:original_source) { "class Calc\n  def add(a, b)\n    a + b\n  end\nend\n" }
  let(:mutations) do
    [
      { id: 1, type: :arithmetic, line: 3, description: 'add broken', code: original_source.sub('a + b', 'a - b') },
      { id: 2, type: :arithmetic, line: 3, description: 'equivalent', code: original_source.sub('a + b', 'b + a') }
    ]
  end

  before do
    FileUtils.mkdir_p(File.dirname(source_file))
    FileUtils.mkdir_p(File.dirname(test_file))
    FileUtils.mkdir_p(File.join(project_root, '.git'))
    File.write(source_file, original_source)
    File.write(test_file, <<~RUBY)
      abort 'minitest was loaded before the test file could pin its version' if defined?(Minitest)

      require 'minitest/autorun'
      require_relative '../lib/calc'

      class CalcTest < Minitest::Test
        def test_adds
          assert_equal 3, Calc.new.add(1, 2)
        end
      end
    RUBY
  end

  after do
    MutationTester::ForkRunner.shutdown_all
    FileUtils.remove_entry(tmp_dir)
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

  def build_config(runner_mode, kill_matrix: false)
    config = MutationTester::Configuration.new
    config.runner = runner_mode
    config.parallel_processes = 1
    config.timeout = 30
    config.kill_matrix = kill_matrix
    config.show_progress = false
    config.reporters = []
    config
  end

  it 'does not load minitest from the preload files themselves' do
    loaded = system(
      RbConfig.ruby,
      '-r', MutationTester::TestCommand::MINITEST_FAIL_FAST_PATH,
      '-r', MutationTester::TestRecorder::MINITEST_HOOK_PATH,
      '-e', 'exit(defined?(Minitest) ? 1 : 0)',
      err: File::NULL
    )

    expect(loaded).to be(true)
  end

  %i[spawn fork in_memory].each do |runner_mode|
    it "decides mutants by the tests on the #{runner_mode} runner instead of killing every mutant with a load error" do
      runner = MutationTester::MutationRunner.new(source_file, test_file, original_source, build_config(runner_mode))

      results = quietly { Dir.chdir(project_root) { runner.run(mutations) } }

      expect(results.sort_by { |r| r[:id] }.map { |r| r[:status] }).to eq(%i[killed survived])
    end

    it "passes the baseline and records the tests on the #{runner_mode} runner with the kill matrix on" do
      core = MutationTester::Core.new(source_file, test_file, build_config(runner_mode, kill_matrix: true))

      passed = quietly { Dir.chdir(project_root) { core.run } }

      expect(passed).to be(true)
      expect(core.tests.map { |test| test[:id] }).to eq(['CalcTest#test_adds'])
    end
  end
end
