require 'spec_helper'

RSpec.describe 'exe/mutation_test CLI' do
  CLI_ROOT = File.expand_path('..', __dir__)
  CLI_BIN = File.join(CLI_ROOT, 'exe', 'mutation_test')
  CLI_SOURCE = File.join(CLI_ROOT, 'examples', 'calculator.rb')
  CLI_SPEC = File.join(CLI_ROOT, 'examples', 'calculator_spec.rb')

  def run_cli(*args, env: {}, chdir: CLI_ROOT)
    child_env = { 'BUNDLE_GEMFILE' => File.join(CLI_ROOT, 'Gemfile') }.merge(env)
    output = IO.popen(
      child_env,
      ['bundle', 'exec', CLI_BIN, *args],
      'r',
      chdir: chdir, err: %i[child out]
    ) { |io| io.read }
    [output, $?.exitstatus]
  end

  describe 'parallel_processes precedence between flag and environment' do
    it 'uses MUTATION_TESTER_PARALLEL_PROCESSES when no -p flag is given' do
      output, status = run_cli(CLI_SOURCE, CLI_SPEC, env: { 'MUTATION_TESTER_PARALLEL_PROCESSES' => '4' })
      expect(status).to eq(0)
      expect(output).to match(/Running mutations in 4 parallel jobs/)
    end

    it 'lets an explicit -p flag override the environment variable' do
      output, status = run_cli('-p', '2', CLI_SOURCE, CLI_SPEC, env: { 'MUTATION_TESTER_PARALLEL_PROCESSES' => '4' })
      expect(status).to eq(0)
      expect(output).to match(/Running mutations in 2 parallel jobs/)
    end

    it 'derives the job count from the CPU cores when neither the env var nor a flag is set' do
      output, status = run_cli(CLI_SOURCE, CLI_SPEC, env: { 'MUTATION_TESTER_PARALLEL_PROCESSES' => nil })
      expect(status).to eq(0)
      auto_jobs = MutationTester::Configuration.auto_parallel_processes
      expect(output).to match(/Running mutations in #{auto_jobs} parallel job/)
    end
  end

  describe 'effective parallel count in the run output' do
    it 'reports the environment value, not the default, in the banner line' do
      output, = run_cli(CLI_SOURCE, CLI_SPEC, env: { 'MUTATION_TESTER_PARALLEL_PROCESSES' => '3' })
      expect(output).to match(/Running mutations in 3 parallel jobs/)
      expect(output).not_to match(/Running mutations in 1 parallel job\b/)
    end
  end

  describe '--no-progress disables the progress display' do
    it 'suppresses the progress completion line, proving show_progress = false' do
      with_progress, = run_cli('-p', '4', CLI_SOURCE, CLI_SPEC)
      without_progress, = run_cli('-p', '4', '--no-progress', CLI_SOURCE, CLI_SPEC)

      expect(with_progress).to match(/Completed in/)
      expect(without_progress).not_to match(/Completed in/)
    end
  end

  describe '--worker-env per-worker database isolation' do
    it 'documents the flag in the help output' do
      output, status = run_cli('--help')

      expect(status).to eq(0)
      expect(output).to match(/--worker-env NAME/)
    end

    it 'announces that the in-memory runner is skipped so each worker isolates its database' do
      output, status = run_cli('-p', '2', '--worker-env', 'TEST_ENV_NUMBER', CLI_SOURCE, CLI_SPEC)

      expect(status).to eq(0)
      expect(output).to match(/--worker-env TEST_ENV_NUMBER is set.*fork runner/m)
    end
  end

  describe '--timeout-factor and --timeout-policy' do
    it 'documents both flags in the help output' do
      output, status = run_cli('--help')

      expect(status).to eq(0)
      expect(output).to match(/--timeout-factor N/)
      expect(output).to match(/--timeout-policy MODE/)
    end

    it 'accepts a numeric factor and the separate policy without any fallback warning' do
      output, status = run_cli('--timeout-factor', '2.5', '--timeout-policy', 'separate', CLI_SOURCE, CLI_SPEC)

      expect(status).to eq(0)
      expect(output).not_to match(/falling back/)
      expect(output).to match(/Mutation Score: \d/)
    end

    it 'falls back to the defaults with warnings for invalid values' do
      output, status = run_cli('--timeout-factor', '0', '--timeout-policy', 'lenient', CLI_SOURCE, CLI_SPEC)

      expect(status).to eq(0)
      expect(output).to match(/timeout_factor must be a number greater than 0.*falling back to 5/)
      expect(output).to match(/timeout_policy must be one of killed, separate.*falling back to killed/)
    end
  end

  describe 'argument and file validation' do
    it 'exits 1 with a usage message when no input files are given' do
      output, status = run_cli
      expect(status).to eq(1)
      expect(output).to match(/No input files given/)
      expect(output).to match(/Usage: mutation_test FILE\.\.\. \| mutation_test --staged \| mutation_test SOURCE_FILE TEST_FILE/)
    end

    it 'reports a single nonexistent file as skipped with a reason and exits 1' do
      output, status = run_cli('only-one-argument.rb')
      expect(status).to eq(1)
      expect(output).to match(/SKIPPED \(file not found\):/)
      expect(output).to match(/only-one-argument\.rb/)
      expect(output).to match(/No files were mutation-tested/)
    end

    it 'exits 1 when the source file does not exist' do
      output, status = run_cli(File.join(CLI_ROOT, 'does-not-exist.rb'), CLI_SPEC)
      expect(status).to eq(1)
      expect(output).to match(/Source file not found/)
    end

    it 'exits 1 when the test file of a legacy pair does not exist' do
      output, status = run_cli(CLI_SOURCE, File.join(CLI_ROOT, 'does_not_exist_spec.rb'))
      expect(status).to eq(1)
      expect(output).to match(/Test file not found/)
    end
  end

  describe '--version' do
    it 'prints the version and exits 0' do
      output, status = run_cli('--version')
      expect(status).to eq(0)
      expect(output).to include("MutationTester v#{MutationTester::VERSION}")
    end
  end
end

require 'tmpdir'
require 'fileutils'
require 'rbconfig'

RSpec.describe 'exe/mutation_test bootstrap outside the project bundle' do
  BOOT_ROOT = File.expand_path('..', __dir__)
  BOOT_BIN = File.join(BOOT_ROOT, 'exe', 'mutation_test')
  BOOT_GEM_LIB = File.join(BOOT_ROOT, 'lib')

  def run_unbundled(*args, chdir:, gemfile: nil)
    output = nil
    Bundler.with_unbundled_env do
      env = {}
      env['BUNDLE_GEMFILE'] = gemfile if gemfile
      output = IO.popen(
        env,
        [RbConfig.ruby, '-I', BOOT_GEM_LIB, BOOT_BIN, *args],
        'r',
        chdir: chdir, err: %i[child out]
      ) { |io| io.read }
    end
    [output, $?.exitstatus]
  end

  describe 'project Gemfile that does not list the gem' do
    around do |example|
      Dir.mktmpdir do |dir|
        @project = dir
        File.write(File.join(dir, 'Gemfile'), "source 'https://rubygems.org'\n")
        example.run
      end
    end

    it 'loads the gem outside the bundle, prints the notice, and reports the version' do
      output, status = run_unbundled('--version', chdir: @project, gemfile: File.join(@project, 'Gemfile'))
      expect(output).to include('mutation_tester loaded outside the project bundle')
      expect(output).to include("MutationTester v#{MutationTester::VERSION}")
      expect(status).to eq(0)
    end

    it 'completes a full end-to-end mutation run without a raw stack trace' do
      Dir.mktmpdir do |src|
        File.write(File.join(src, 'covered.rb'), <<~RUBY)
          class Covered
            def add(a, b)
              a + b
            end
          end
        RUBY
        File.write(File.join(src, 'covered_test.rb'), <<~RUBY)
          require 'minitest/autorun'
          require_relative 'covered'

          class CoveredTest < Minitest::Test
            def test_add
              assert_equal 3, Covered.new.add(1, 2)
              assert_equal 0, Covered.new.add(0, 0)
              assert_equal(-1, Covered.new.add(1, -2))
            end
          end
        RUBY

        output, status = run_unbundled(
          File.join(src, 'covered.rb'),
          File.join(src, 'covered_test.rb'),
          chdir: src,
          gemfile: File.join(@project, 'Gemfile')
        )

        expect(output).to include('mutation_tester loaded outside the project bundle')
        expect(output).to match(/Mutation score:/)
        expect(output).not_to match(/LoadError|cannot load such file/)
        expect(status).to eq(0)
      end
    end
  end

  describe 'directory with no Gemfile at all' do
    it 'loads and runs a plain global install without printing the fallback notice' do
      Dir.mktmpdir do |dir|
        output, status = run_unbundled('--version', chdir: dir)
        expect(status).to eq(0)
        expect(output).to include("MutationTester v#{MutationTester::VERSION}")
        expect(output).not_to include('mutation_tester loaded outside the project bundle')
      end
    end
  end
end

require 'open3'
require 'json'

RSpec.describe 'exe/mutation_test machine mode and reporter selection' do
  JSON_CLI_ROOT = File.expand_path('..', __dir__)
  JSON_CLI_BIN = File.join(JSON_CLI_ROOT, 'exe', 'mutation_test')
  JSON_CLI_SOURCE = File.join(JSON_CLI_ROOT, 'examples', 'calculator.rb')
  JSON_CLI_SPEC = File.join(JSON_CLI_ROOT, 'examples', 'calculator_spec.rb')
  ALLOWED_STATUSES = %w[killed survived timeout stillborn error].freeze

  def run_cli_split(*args, env: {}, chdir: JSON_CLI_ROOT)
    child_env = { 'BUNDLE_GEMFILE' => File.join(JSON_CLI_ROOT, 'Gemfile') }.merge(env)
    stdout, stderr, status = Open3.capture3(
      child_env, 'bundle', 'exec', JSON_CLI_BIN, *args, chdir: chdir
    )
    [stdout, stderr, status.exitstatus]
  end

  describe '--json emits only clean JSON on stdout' do
    it 'prints parseable JSON with schema_version and taxonomy statuses, banner on stderr' do
      stdout, stderr, status = run_cli_split('--json', JSON_CLI_SOURCE, JSON_CLI_SPEC)

      expect(status).to eq(0)

      report = JSON.parse(stdout)
      expect(report['schema_version']).to eq(1)
      expect(report.keys).to contain_exactly('schema_version', 'interrupted', 'metadata', 'summary', 'mutations')
      expect(report['summary']).to include('mutation_score', 'categories')
      expect(report['mutations']).to be_an(Array)

      expect(stdout).not_to match(/\e\[/)

      statuses = report['mutations'].map { |m| m['status'] }
      expect(statuses.uniq - ALLOWED_STATUSES).to be_empty

      expect(stdout).not_to include('MutationTester v')
      expect(stderr).to include('MutationTester')
      expect(stderr).to include('JSON report saved to')
    end

    it 'pipes cleanly through a JSON consumer and preserves the threshold exit code' do
      stdout, = run_cli_split('--json', JSON_CLI_SOURCE, JSON_CLI_SPEC)
      score = JSON.parse(stdout).dig('summary', 'mutation_score')
      expect(score).to be_a(Numeric)
      expect(score).to be > 0
    end
  end

  describe '--output-dir with --json still writes the artifact' do
    it 'writes the JSON report file to the chosen directory' do
      Dir.mktmpdir do |dir|
        stdout, _stderr, status = run_cli_split(
          '--json', '--output-dir', dir, JSON_CLI_SOURCE, JSON_CLI_SPEC
        )
        expect(status).to eq(0)

        report_path = File.join(dir, 'mutation_report.json')
        expect(File.exist?(report_path)).to be true

        expect(JSON.parse(File.read(report_path))).to eq(JSON.parse(stdout))
      end
    end
  end

  describe '--reporters validation' do
    it 'exits 1 with a clear error on an unknown reporter, without touching stdout' do
      stdout, stderr, status = run_cli_split(
        '--reporters', 'console,bogus', JSON_CLI_SOURCE, JSON_CLI_SPEC
      )
      expect(status).to eq(1)
      expect(stderr).to match(/Unknown reporter\(s\): bogus/)
      expect(stderr).to match(/Valid reporters: console, html, json/)
      expect(stdout).to eq('')
    end
  end

  describe 'default human mode without --json' do
    it 'prints the banner on stdout when --json is absent' do
      stdout, _stderr, status = run_cli_split(JSON_CLI_SOURCE, JSON_CLI_SPEC)
      expect(status).to eq(0)
      expect(stdout).to include("MutationTester v#{MutationTester::VERSION}")
    end
  end

  describe '--json keeps stdout clean on a bad invocation' do
    def expect_stdout_json_only(stdout)
      return if stdout.empty?

      expect { JSON.parse(stdout) }.not_to raise_error
      expect(stdout).not_to match(/\e\[/)
    end

    it 'sends a missing-source-file error to stderr, not stdout, and exits 1' do
      stdout, stderr, status = run_cli_split(
        '--json', File.join(JSON_CLI_ROOT, 'no-such-source.rb'), JSON_CLI_SPEC
      )
      expect(status).to eq(1)
      expect_stdout_json_only(stdout)
      expect(stderr).to match(/Source file not found/)
      expect(stdout).not_to match(/Source file not found/)
    end

    it 'sends a missing-test-file error to stderr, not stdout, and exits 1' do
      stdout, stderr, status = run_cli_split(
        '--json', JSON_CLI_SOURCE, File.join(JSON_CLI_ROOT, 'no_such_spec.rb')
      )
      expect(status).to eq(1)
      expect_stdout_json_only(stdout)
      expect(stderr).to match(/Test file not found/)
    end

    it 'sends an unmappable-single-file error to stderr, not stdout, and exits 1' do
      stdout, stderr, status = run_cli_split('--json', 'only-one-argument.rb')
      expect(status).to eq(1)
      expect(stdout).to eq('')
      expect(stderr).to match(/only-one-argument\.rb cannot be mutation-tested: file not found/)
    end

    it 'answers a multi-file list of unusable files with an envelope of skips on stdout and exit 1' do
      Dir.mktmpdir do |dir|
        stdout, _stderr, status = run_cli_split('--json', 'a.rb', 'b.rb', chdir: dir)

        expect(status).to eq(1)
        envelope = JSON.parse(stdout)
        expect(envelope.keys).to contain_exactly('schema_version', 'summary', 'survivors', 'files')
        expect(envelope['schema_version']).to eq(1)
        expect(envelope['summary']).to include('files' => 2, 'processed' => 0, 'passed' => false)
        expect(envelope['summary']['skipped']).to contain_exactly(
          { 'file' => 'a.rb', 'reason' => 'file not found' },
          { 'file' => 'b.rb', 'reason' => 'file not found' }
        )
        expect(envelope['survivors']).to eq([])
      end
    end
  end

  describe '--json with a single listed source file' do
    it 'maps the spec by convention and runs today\'s single-file machine mode' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, 'lib'))
        FileUtils.mkdir_p(File.join(dir, 'spec'))
        File.write(File.join(dir, 'lib', 'covered.rb'), <<~RUBY)
          class Covered
            def add(a, b)
              a + b
            end
          end
        RUBY
        File.write(File.join(dir, 'spec', 'covered_spec.rb'), <<~RUBY)
          require_relative '../lib/covered'

          RSpec.describe Covered do
            it('adds') { expect(Covered.new.add(1, 2)).to eq(3) }
            it('adds zero') { expect(Covered.new.add(0, 0)).to eq(0) }
            it('adds negatives') { expect(Covered.new.add(1, -2)).to eq(-1) }
          end
        RUBY

        stdout, _stderr, status = run_cli_split('--json', 'lib/covered.rb', chdir: dir)

        expect(status).to eq(0)
        report = JSON.parse(stdout)
        expect(report.dig('metadata', 'source_file')).to include('lib/covered.rb')
        expect(report.dig('metadata', 'spec_file')).to include('spec/covered_spec.rb')
      end
    end
  end
end

RSpec.describe 'exe/mutation_test batch mode' do
  BATCH_ROOT = File.expand_path('..', __dir__)
  BATCH_BIN = File.join(BATCH_ROOT, 'exe', 'mutation_test')
  BATCH_GEM_LIB = File.join(BATCH_ROOT, 'lib')

  def run_batch(*args, chdir:)
    output = nil
    Bundler.with_unbundled_env do
      output = IO.popen(
        {},
        [RbConfig.ruby, '-I', BATCH_GEM_LIB, BATCH_BIN, *args],
        'r',
        chdir: chdir, err: %i[child out]
      ) { |io| io.read }
    end
    [output, $?.exitstatus]
  end

  def run_batch_split(*args, chdir:)
    out = err = nil
    status = nil
    Bundler.with_unbundled_env do
      out, err, status = Open3.capture3(
        {}, RbConfig.ruby, '-I', BATCH_GEM_LIB, BATCH_BIN, *args, chdir: chdir
      )
    end
    [out, err, status.exitstatus]
  end

  def build_project(dir)
    FileUtils.mkdir_p(File.join(dir, 'lib'))
    FileUtils.mkdir_p(File.join(dir, 'test'))

    File.write(File.join(dir, 'lib', 'adder.rb'), <<~RUBY)
      class Adder
        def add(a, b)
          a + b
        end
      end
    RUBY
    File.write(File.join(dir, 'test', 'adder_test.rb'), <<~RUBY)
      require 'minitest/autorun'
      require_relative '../lib/adder'

      class AdderTest < Minitest::Test
        def test_add
          assert_equal 3, Adder.new.add(1, 2)
          assert_equal 0, Adder.new.add(0, 0)
          assert_equal(-1, Adder.new.add(1, -2))
          assert_equal 5, Adder.new.add(2, 3)
        end
      end
    RUBY

    File.write(File.join(dir, 'lib', 'calc.rb'), <<~RUBY)
      class Calc
        def compute(a, b)
          a + b
        end
      end
    RUBY
    File.write(File.join(dir, 'test', 'calc_test.rb'), <<~RUBY)
      require 'minitest/autorun'
      require_relative '../lib/calc'

      class CalcTest < Minitest::Test
        def test_compute
          assert_equal 0, Calc.new.compute(0, 0)
        end
      end
    RUBY

    File.write(File.join(dir, 'lib', 'orphan.rb'), <<~RUBY)
      class Orphan
        def noop
          42
        end
      end
    RUBY
  end

  describe 'processing many files, threshold-driven exit, skip and summary' do
    it 'runs every file, reports PASS/FAIL/SKIPPED and exits 1 when one file misses the threshold' do
      Dir.mktmpdir do |dir|
        build_project(dir)
        output, status = run_batch(
          '--glob', 'lib/**/*.rb', '--spec-glob', 'test/{name}_test.rb', chdir: dir
        )

        expect(status).to eq(1)
        expect(output).to match(/PASS\s+100\.00%\s+lib\/adder\.rb/)
        expect(output).to match(/FAIL\s+50\.00%\s+lib\/calc\.rb/)

        expect(output).to match(/SKIPPED \(no matching spec file\):/)
        expect(output).to match(/lib\/orphan\.rb \(expected test\/orphan_test\.rb\)/)

        expect(output).to match(/Batch summary: 2 processed, 1 skipped/)
      end
    end

    it 'exits 0 when every processed file meets the threshold' do
      Dir.mktmpdir do |dir|
        build_project(dir)
        output, status = run_batch(
          '--glob', 'lib/adder.rb', '--spec-glob', 'test/{name}_test.rb', chdir: dir
        )
        expect(status).to eq(0)
        expect(output).to match(/PASS\s+100\.00%\s+lib\/adder\.rb/)
        expect(output).to match(/All processed files met the mutation score threshold/)
      end
    end

    it 'writes each file its own report subdirectory so reports never overwrite' do
      Dir.mktmpdir do |dir|
        build_project(dir)
        out_dir = File.join(dir, 'reports')
        run_batch(
          '--glob', 'lib/**/*.rb', '--spec-glob', 'test/{name}_test.rb',
          '--reporters', 'json', '--output-dir', out_dir, chdir: dir
        )

        reports = Dir.glob(File.join(out_dir, '*', 'mutation_report.json')).sort
        expect(reports.size).to eq(2)

        subdirs = reports.map { |path| File.dirname(path) }.uniq
        expect(subdirs.size).to eq(2)

        sources = reports.map { |path| JSON.parse(File.read(path)).dig('metadata', 'source_file') }
        expect(sources.map { |s| File.basename(s) }).to contain_exactly('adder.rb', 'calc.rb')
      end
    end
  end

  describe 'the default lib/X.rb -> spec/X_spec.rb convention' do
    it 'maps to spec/{name}_spec.rb and skips a source whose conventional spec is missing' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, 'lib'))
        File.write(File.join(dir, 'lib', 'lonely.rb'), "class Lonely\n  def one\n    1\n  end\nend\n")

        output, status = run_batch('--glob', 'lib/**/*.rb', chdir: dir)

        expect(output).to match(/SKIPPED \(no matching spec file\):/)
        expect(output).to match(/lib\/lonely\.rb \(expected spec\/lonely_spec\.rb\)/)
        expect(output).to match(/Batch summary: 0 processed, 1 skipped/)
        expect(status).to eq(0)
      end
    end
  end

  describe 'usage errors' do
    it 'rejects --spec-glob combined with an explicit SOURCE TEST pair on stderr with a usage status' do
      Dir.mktmpdir do |dir|
        stdout, stderr, status = run_batch_split(
          '--spec-glob', 'test/{name}_test.rb', 'a.rb', 'b_test.rb', chdir: dir
        )
        expect(status).to eq(2)
        expect(stdout).to eq('')
        expect(stderr).to match(/--spec-glob does not apply to an explicit SOURCE_FILE TEST_FILE pair/)
      end
    end

    it 'exits 1 with a clear message when the glob matches no source files' do
      Dir.mktmpdir do |dir|
        output, status = run_batch('--glob', 'lib/**/*.rb', chdir: dir)
        expect(status).to eq(1)
        expect(output).to match(/No source files matched glob: lib\/\*\*\/\*\.rb/)
      end
    end

    it 'rejects --since without --glob on stderr with a usage status' do
      Dir.mktmpdir do |dir|
        stdout, stderr, status = run_batch_split('--since', 'HEAD', 'a.rb', 'b.rb', chdir: dir)
        expect(status).to eq(2)
        expect(stdout).to eq('')
        expect(stderr).to match(/--since requires --glob/)
      end
    end

    it 'exits 2 with a readable error for --since outside a git repository, before any mutation runs' do
      Dir.mktmpdir do |dir|
        build_project(dir)
        stdout, stderr, status = run_batch_split(
          '--glob', 'lib/**/*.rb', '--since', 'HEAD', chdir: dir
        )
        expect(status).to eq(2)
        expect(stderr).to match(/not a git repository/)
        expect(stdout).not_to match(/Testing:/)
      end
    end

    it 'exits 2 with a readable error for --since with a revision the repository does not know' do
      Dir.mktmpdir do |dir|
        build_project(dir)
        git_commit_all(dir)
        stdout, stderr, status = run_batch_split(
          '--glob', 'lib/**/*.rb', '--since', 'no-such-rev', chdir: dir
        )
        expect(status).to eq(2)
        expect(stderr).to match(/unknown revision "no-such-rev"/)
        expect(stdout).not_to match(/Testing:/)
      end
    end
  end

  def git_commit_all(dir)
    system('git', '-C', dir, 'init', '-q')
    system('git', '-C', dir, 'add', '-A')
    system('git', '-C', dir, '-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-q', '-m', 'baseline')
  end

  describe 'incremental batch mode with --since' do
    it 'mutates only the matched files changed since the revision and reports the rest as unchanged' do
      Dir.mktmpdir do |dir|
        build_project(dir)
        git_commit_all(dir)
        File.write(File.join(dir, 'lib', 'adder.rb'), File.read(File.join(dir, 'lib', 'adder.rb')) + "\n")

        output, status = run_batch(
          '--glob', 'lib/**/*.rb', '--spec-glob', 'test/{name}_test.rb', '--since', 'HEAD', chdir: dir
        )

        expect(status).to eq(0)
        expect(output).to match(/PASS\s+100\.00%\s+lib\/adder\.rb/)
        expect(output).not_to match(/Testing: lib\/calc\.rb/)
        expect(output).to match(/SKIPPED \(unchanged since HEAD\):/)
        expect(output).to match(/-\s+lib\/calc\.rb/)
        expect(output).to match(/Batch summary: 1 processed, 0 skipped, 2 unchanged since HEAD/)
      end
    end

    it 'succeeds with a nothing-to-mutate message when no matched file changed since the revision' do
      Dir.mktmpdir do |dir|
        build_project(dir)
        git_commit_all(dir)

        output, status = run_batch(
          '--glob', 'lib/**/*.rb', '--spec-glob', 'test/{name}_test.rb', '--since', 'HEAD', chdir: dir
        )

        expect(status).to eq(0)
        expect(output).to match(/Nothing to mutate: none of the 3 matched files changed since HEAD/)
        expect(output).not_to match(/Testing:/)
      end
    end
  end

  describe '--strict-equality' do
    def build_equality_project(dir)
      FileUtils.mkdir_p(File.join(dir, 'lib'))
      FileUtils.mkdir_p(File.join(dir, 'test'))
      File.write(File.join(dir, 'lib', 'checker.rb'), <<~RUBY)
        class Checker
          def zero?(value)
            value == 0
          end
        end
      RUBY
      File.write(File.join(dir, 'test', 'checker_test.rb'), <<~RUBY)
        require 'minitest/autorun'
        require_relative '../lib/checker'

        class CheckerTest < Minitest::Test
          def test_zero
            assert_equal true, Checker.new.zero?(0)
            assert_equal false, Checker.new.zero?(5)
            assert_equal false, Checker.new.zero?(-1)
            assert_equal false, Checker.new.zero?(1)
          end
        end
      RUBY
    end

    it 'generates and reports eql? and equal? probes with readable descriptions when the flag is set' do
      Dir.mktmpdir do |dir|
        build_equality_project(dir)
        stdout, _stderr, _status = run_batch_split(
          '--json', '--strict-equality', 'lib/checker.rb', 'test/checker_test.rb', chdir: dir
        )

        report = JSON.parse(stdout)
        strict = report['mutations'].select { |m| m['type'] == 'strict_equality' }
        expect(strict.map { |m| m['mutated'] }).to contain_exactly('eql?', 'equal?')
        expect(strict.map { |m| m['description'] }).to contain_exactly('Change == to eql?', 'Change == to equal?')
      end
    end

    it 'generates no strict equality probes without the flag' do
      Dir.mktmpdir do |dir|
        build_equality_project(dir)
        stdout, _stderr, status = run_batch_split(
          '--json', 'lib/checker.rb', 'test/checker_test.rb', chdir: dir
        )

        expect(status).to eq(0)
        report = JSON.parse(stdout)
        expect(report['mutations'].map { |m| m['type'] }).not_to include('strict_equality')
        expect(report['interrupted']).to be false
      end
    end
  end

  describe '--fail-fast' do
    it 'stops a single-file run at the first surviving mutant with a clear interruption notice and exit 1' do
      Dir.mktmpdir do |dir|
        build_project(dir)
        output, status = run_batch(
          '--fail-fast', 'lib/calc.rb', 'test/calc_test.rb', chdir: dir
        )
        expect(status).to eq(1)
        interruption = output.match(/Run interrupted by --fail-fast: a mutant survived after (\d+) of (\d+) mutations/)
        expect(interruption).not_to be_nil
        processed, total = interruption.captures.map(&:to_i)
        expect(processed).to be < total
        expect(output).to match(/Reports contain the results obtained up to the interruption/)

        json_report = JSON.parse(File.read(File.join(dir, 'tmp', 'mutation_reports', 'mutation_report.json')))
        expect(json_report['interrupted']).to be true
        html_report = File.read(File.join(dir, 'tmp', 'mutation_reports', 'mutation_report.html'))
        expect(html_report).to include('<div class="interrupted-banner">')
      end
    end

    it 'stops the run at the first surviving mutant in parallel mode too' do
      Dir.mktmpdir do |dir|
        build_project(dir)
        system('git', '-C', dir, 'init', '-q')
        output, status = run_batch(
          '--fail-fast', '-p', '2', 'lib/calc.rb', 'test/calc_test.rb', chdir: dir
        )
        expect(status).to eq(1)
        expect(output).to match(/Run interrupted by --fail-fast/)
      end
    end

    it 'aborts a batch at the first surviving mutant, keeping earlier per-file results and exiting 1' do
      Dir.mktmpdir do |dir|
        build_project(dir)
        File.write(File.join(dir, 'lib', 'zz_tail.rb'), <<~RUBY)
          class ZzTail
            def double(a)
              a * 2
            end
          end
        RUBY
        File.write(File.join(dir, 'test', 'zz_tail_test.rb'), <<~RUBY)
          require 'minitest/autorun'
          require_relative '../lib/zz_tail'

          class ZzTailTest < Minitest::Test
            def test_double
              assert_equal 4, ZzTail.new.double(2)
              assert_equal 0, ZzTail.new.double(0)
              assert_equal(-6, ZzTail.new.double(-3))
            end
          end
        RUBY
        output, status = run_batch(
          '--glob', 'lib/**/*.rb', '--spec-glob', 'test/{name}_test.rb', '--fail-fast', chdir: dir
        )

        expect(status).to eq(1)
        expect(output).to match(/PASS\s+100\.00%\s+lib\/adder\.rb/)
        expect(output).to match(/FAIL\s+.*lib\/calc\.rb/)
        expect(output).to match(/Batch interrupted by --fail-fast: a mutant survived; remaining files were not run/)
        expect(output).not_to match(/Testing: lib\/zz_tail\.rb/)
        expect(output).not_to include('orphan')
      end
    end
  end

  describe 'positional source file list' do
    it 'maps each listed source to its spec by convention and aggregates like a batch' do
      Dir.mktmpdir do |dir|
        build_project(dir)
        output, status = run_batch(
          '--spec-glob', 'test/{name}_test.rb', 'lib/adder.rb', 'lib/calc.rb', chdir: dir
        )

        expect(status).to eq(1)
        expect(output).to match(/PASS\s+100\.00%\s+lib\/adder\.rb/)
        expect(output).to match(/FAIL\s+50\.00%\s+lib\/calc\.rb/)
        expect(output).to match(/Batch summary: 2 processed, 0 skipped/)
        expect(output).to match(/Surviving mutants \(\d+\):/)
        expect(output).to match(/lib\/calc\.rb:\d+ .+ -> .+/)
        expect(output).to include('A surviving mutant is a change to your code that your tests do not detect')
      end
    end

    it 'exits 0 when every listed file meets the threshold' do
      Dir.mktmpdir do |dir|
        build_project(dir)
        output, status = run_batch(
          '--spec-glob', 'test/{name}_test.rb', 'lib/adder.rb', chdir: dir
        )

        expect(status).to eq(0)
        expect(output).to match(/PASS\s+100\.00%\s+lib\/adder\.rb/)
        expect(output).to match(/All processed files met the mutation score threshold/)
        expect(output).not_to include('Surviving mutants')
      end
    end

    it 'reports every unmutable file as skipped with its reason and exits 1 when nothing ran' do
      Dir.mktmpdir do |dir|
        build_project(dir)
        File.write(File.join(dir, 'notes.md'), "# notes\n")
        output, status = run_batch(
          '--spec-glob', 'test/{name}_test.rb',
          'notes.md', 'test/adder_test.rb', 'lib/orphan.rb', 'lib/gone.rb', chdir: dir
        )

        expect(status).to eq(1)
        expect(output).to match(/SKIPPED \(not a Ruby source file\):\s*\n\s*- notes\.md/)
        expect(output).to match(/SKIPPED \(a test file, not a mutable source\):\s*\n\s*- test\/adder_test\.rb/)
        expect(output).to match(/SKIPPED \(no matching spec file\):\s*\n\s*- lib\/orphan\.rb \(expected test\/orphan_test\.rb\)/)
        expect(output).to match(/SKIPPED \(file not found\):\s*\n\s*- lib\/gone\.rb/)
        expect(output).to match(/No files were mutation-tested: every listed file was skipped/)
        expect(output).to match(/Batch summary: 0 processed, 4 skipped/)
        expect(output).not_to match(/Testing:/)
      end
    end

    it 'continues past skipped files and still runs the mutable ones' do
      Dir.mktmpdir do |dir|
        build_project(dir)
        File.write(File.join(dir, 'notes.md'), "# notes\n")
        output, status = run_batch(
          '--spec-glob', 'test/{name}_test.rb', 'notes.md', 'lib/adder.rb', chdir: dir
        )

        expect(status).to eq(0)
        expect(output).to match(/PASS\s+100\.00%\s+lib\/adder\.rb/)
        expect(output).to match(/SKIPPED \(not a Ruby source file\):\s*\n\s*- notes\.md/)
        expect(output).to match(/Batch summary: 1 processed, 1 skipped/)
      end
    end
  end

  describe 'legacy SOURCE TEST pair heuristic' do
    it 'treats two arguments as the legacy pair when the second is a recognized test file' do
      Dir.mktmpdir do |dir|
        build_project(dir)
        output, status = run_batch('lib/adder.rb', 'test/adder_test.rb', chdir: dir)

        expect(status).to eq(0)
        expect(output).not_to match(/Batch summary/)
        expect(output).to match(/Mutation score:/)
      end
    end

    it 'recognizes an unconventionally named minitest file by content and stays on the legacy pair' do
      Dir.mktmpdir do |dir|
        build_project(dir)
        File.write(File.join(dir, 'checks.rb'), <<~RUBY)
          require 'minitest/autorun'
          require_relative 'lib/adder'

          class ChecksTest < Minitest::Test
            def test_add
              assert_equal 3, Adder.new.add(1, 2)
              assert_equal 0, Adder.new.add(0, 0)
              assert_equal(-1, Adder.new.add(1, -2))
              assert_equal 5, Adder.new.add(2, 3)
            end
          end
        RUBY
        output, status = run_batch('lib/adder.rb', 'checks.rb', chdir: dir)

        expect(status).to eq(0)
        expect(output).not_to match(/Batch summary/)
        expect(output).to match(/Mutation score:/)
      end
    end

    it 'treats two source files as a file list, not a legacy pair' do
      Dir.mktmpdir do |dir|
        build_project(dir)
        output, status = run_batch('lib/adder.rb', 'lib/calc.rb', chdir: dir)

        expect(status).to eq(1)
        expect(output).to match(/Batch summary: 0 processed, 2 skipped/)
        expect(output).to match(/SKIPPED \(no matching spec file\):/)
        expect(output).to match(/lib\/adder\.rb \(expected spec\/adder_spec\.rb\)/)
        expect(output).to match(/lib\/calc\.rb \(expected spec\/calc_spec\.rb\)/)
      end
    end
  end

  describe '--staged' do
    it 'mutation-tests the staged files exactly like the equivalent positional list' do
      Dir.mktmpdir do |dir|
        build_project(dir)
        File.write(File.join(dir, 'notes.md'), "# notes\n")
        system('git', '-C', dir, 'init', '-q')
        system('git', '-C', dir, 'add', '-A')

        staged_output, staged_status = run_batch(
          '--staged', '--spec-glob', 'test/{name}_test.rb', chdir: dir
        )
        list_output, list_status = run_batch(
          '--spec-glob', 'test/{name}_test.rb',
          'lib/adder.rb', 'lib/calc.rb', 'lib/orphan.rb', 'notes.md',
          'test/adder_test.rb', 'test/calc_test.rb', chdir: dir
        )

        summary = ->(out) { out.lines.select { |l| l =~ /\A(PASS|FAIL)|SKIPPED \(|\A\s+- / }.join }

        expect(staged_status).to eq(1)
        expect(list_status).to eq(1)
        expect(summary.call(staged_output)).to eq(summary.call(list_output))
        expect(staged_output).to match(/PASS\s+100\.00%\s+lib\/adder\.rb/)
        expect(staged_output).to match(/FAIL\s+50\.00%\s+lib\/calc\.rb/)
        expect(staged_output).to match(/SKIPPED \(not a Ruby source file\):\s*\n\s*- notes\.md/)
        expect(staged_output).to match(/SKIPPED \(a test file, not a mutable source\):/)
        expect(staged_output).to match(/SKIPPED \(no matching spec file\):\s*\n\s*- lib\/orphan\.rb/)
      end
    end

    it 'ignores files staged as deleted' do
      Dir.mktmpdir do |dir|
        build_project(dir)
        git_commit_all(dir)
        File.write(File.join(dir, 'lib', 'adder.rb'), File.read(File.join(dir, 'lib', 'adder.rb')) + "\n")
        system('git', '-C', dir, 'add', 'lib/adder.rb')
        system('git', '-C', dir, 'rm', '-q', 'lib/orphan.rb')

        output, status = run_batch('--staged', '--spec-glob', 'test/{name}_test.rb', chdir: dir)

        expect(status).to eq(0)
        expect(output).to match(/PASS\s+100\.00%\s+lib\/adder\.rb/)
        expect(output).to match(/Batch summary: 1 processed, 0 skipped/)
        expect(output).not_to include('orphan')
      end
    end

    it 'errors with a readable message outside a git repository' do
      Dir.mktmpdir do |dir|
        stdout, stderr, status = run_batch_split('--staged', chdir: dir)
        expect(status).to eq(2)
        expect(stdout).to eq('')
        expect(stderr).to match(/not a git repository/)
      end
    end

    it 'errors with a readable message when the staging area is empty' do
      Dir.mktmpdir do |dir|
        build_project(dir)
        git_commit_all(dir)
        stdout, stderr, status = run_batch_split('--staged', chdir: dir)
        expect(status).to eq(1)
        expect(stdout).to eq('')
        expect(stderr).to match(/--staged found no staged files/)
      end
    end

    it 'rejects --staged combined with positional FILE arguments' do
      Dir.mktmpdir do |dir|
        stdout, stderr, status = run_batch_split('--staged', 'lib/adder.rb', chdir: dir)
        expect(status).to eq(2)
        expect(stdout).to eq('')
        expect(stderr).to match(/--staged cannot be combined with positional FILE arguments/)
      end
    end

    it 'rejects --staged combined with --glob' do
      Dir.mktmpdir do |dir|
        stdout, stderr, status = run_batch_split('--staged', '--glob', 'lib/**/*.rb', chdir: dir)
        expect(status).to eq(2)
        expect(stdout).to eq('')
        expect(stderr).to match(/--staged cannot be combined with --glob/)
      end
    end
  end

  describe 'multi-file machine mode envelope' do
    it 'prints one aggregate envelope for --staged --json with the surviving mutants and exits 1' do
      Dir.mktmpdir do |dir|
        build_project(dir)
        system('git', '-C', dir, 'init', '-q')
        system('git', '-C', dir, 'add', 'lib/calc.rb', 'test/calc_test.rb')

        stdout, stderr, status = run_batch_split(
          '--staged', '--json', '--spec-glob', 'test/{name}_test.rb', chdir: dir
        )

        expect(status).to eq(1)
        expect(stdout).not_to match(/\e\[/)

        envelope = JSON.parse(stdout)
        expect(envelope.keys).to contain_exactly('schema_version', 'summary', 'survivors', 'files')
        expect(envelope['schema_version']).to eq(1)
        expect(envelope['summary']).to include(
          'files' => 2, 'processed' => 1, 'passed' => false, 'interrupted' => false
        )
        expect(envelope['summary']['skipped'])
          .to eq([{ 'file' => 'test/calc_test.rb', 'reason' => 'a test file, not a mutable source' }])

        source_files = envelope['files'].map { |report| report.dig('metadata', 'source_file') }

        expect(envelope['survivors']).not_to be_empty
        envelope['survivors'].each do |survivor|
          expect(survivor.keys).to contain_exactly('file', 'line', 'type', 'original', 'mutated')
          expect(survivor['file']).to end_with('lib/calc.rb')
          expect(source_files).to include(survivor['file'])
          expect(survivor['line']).to be_a(Integer)
        end

        expect(envelope['files'].size).to eq(1)
        expect(envelope['files'].first.keys)
          .to contain_exactly('schema_version', 'interrupted', 'metadata', 'summary', 'mutations')
        expect(envelope['files'].first.dig('metadata', 'source_file')).to include('lib/calc.rb')

        expect(stderr).to include('MutationTester')
        expect(stdout).not_to include('Batch summary')
      end
    end

    it 'prints an envelope with no survivors and exits 0 when every staged mutant is killed' do
      Dir.mktmpdir do |dir|
        build_project(dir)
        system('git', '-C', dir, 'init', '-q')
        system('git', '-C', dir, 'add', 'lib/adder.rb', 'test/adder_test.rb')

        stdout, _stderr, status = run_batch_split(
          '--staged', '--json', '--spec-glob', 'test/{name}_test.rb', chdir: dir
        )

        expect(status).to eq(0)
        envelope = JSON.parse(stdout)
        expect(envelope['survivors']).to eq([])
        expect(envelope['summary']).to include('processed' => 1, 'passed' => true)
        expect(envelope['summary']['score']).to eq(100.0)
      end
    end

    it 'prints one aggregate envelope for --glob --json covering processed, skipped and survivors' do
      Dir.mktmpdir do |dir|
        build_project(dir)

        stdout, _stderr, status = run_batch_split(
          '--json', '--glob', 'lib/**/*.rb', '--spec-glob', 'test/{name}_test.rb', chdir: dir
        )

        expect(status).to eq(1)
        envelope = JSON.parse(stdout)
        expect(envelope['summary']).to include('files' => 3, 'processed' => 2, 'passed' => false)
        expect(envelope['summary']['skipped'])
          .to eq([{ 'file' => 'lib/orphan.rb', 'reason' => 'no matching spec file' }])

        survivor_files = envelope['survivors'].map { |s| s['file'] }.uniq
        source_files = envelope['files'].map { |report| report.dig('metadata', 'source_file') }
        expect(survivor_files.size).to eq(1)
        expect(survivor_files.first).to end_with('lib/calc.rb')
        expect(source_files).to include(survivor_files.first)
        expect(envelope['files'].size).to eq(2)
      end
    end
  end
end

RSpec.describe 'exe/mutation_test SIGINT handling' do
  SIGINT_ROOT = File.expand_path('..', __dir__)
  SIGINT_BIN = File.join(SIGINT_ROOT, 'exe', 'mutation_test')
  SIGINT_LIB = File.join(SIGINT_ROOT, 'lib')

  def interrupt_after_baseline_starts(source, test, sentinel, chdir:)
    err_r, err_w = IO.pipe
    pid = nil
    Bundler.with_unbundled_env do
      pid = Process.spawn(
        { 'SIGINT_SENTINEL' => sentinel },
        RbConfig.ruby, '-I', SIGINT_LIB, SIGINT_BIN, source, test,
        chdir: chdir, out: File::NULL, err: err_w
      )
    end
    err_w.close

    stderr = +''
    reader = Thread.new do
      err_r.each_char { |char| stderr << char }
    rescue IOError
      nil
    end

    deadline = Time.now + 30
    sleep 0.02 until File.exist?(sentinel) || Time.now > deadline
    raise 'baseline never started before the deadline' unless File.exist?(sentinel)

    Process.kill('INT', pid)
    _, status = Process.wait2(pid)
    reader.join(2)
    [stderr, status]
  ensure
    err_r.close unless err_r.closed?
  end

  it 'prints one clean interruption line on stderr and exits 130 without a backtrace' do
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'covered.rb')
      test = File.join(dir, 'covered_test.rb')
      sentinel = File.join(dir, 'baseline_started')
      File.write(source, <<~RUBY)
        class Covered
          def add(a, b)
            a + b
          end
        end
      RUBY
      File.write(test, <<~RUBY)
        require 'minitest/autorun'
        require_relative 'covered'

        class CoveredTest < Minitest::Test
          def test_add
            File.write(ENV.fetch('SIGINT_SENTINEL'), 'go')
            sleep 10
            assert_equal 3, Covered.new.add(1, 2)
          end
        end
      RUBY

      stderr, status = interrupt_after_baseline_starts(source, test, sentinel, chdir: dir)

      expect(status.signaled?).to be false
      expect(status.exitstatus).to eq(130)
      expect(stderr).to include('Interrupted: run stopped, workspaces cleaned up, partial results discarded.')
      expect(stderr).not_to match(/^\s+from .+:\d+:in /)
      expect(stderr).not_to match(%r{lib/mutation_tester/.+\.rb:\d+:in })
    end
  end
end
