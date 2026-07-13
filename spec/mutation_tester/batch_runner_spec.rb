require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'stringio'

RSpec.describe MutationTester::BatchRunner do
  let(:config) { MutationTester::Configuration.new }

  def build_runner(spec_template: nil, changed_files: nil)
    described_class.new(glob: 'lib/**/*.rb', spec_template: spec_template, config: config, changed_files: changed_files)
  end

  def list_runner(files, spec_template: nil)
    described_class.new(files: files, spec_template: spec_template, config: config)
  end

  describe 'input contract' do
    it 'requires exactly one of glob: or files:' do
      expect { described_class.new(glob: 'lib/**/*.rb', files: ['a.rb'], config: config) }
        .to raise_error(ArgumentError, /exactly one of glob: or files:/)
      expect { described_class.new(config: config) }
        .to raise_error(ArgumentError, /exactly one of glob: or files:/)
    end
  end

  describe '.test_file?' do
    it 'recognizes RSpec and Minitest test files by name pattern' do
      expect(described_class.test_file?('spec/foo_spec.rb')).to be true
      expect(described_class.test_file?('spec/foo.spec.rb')).to be true
      expect(described_class.test_file?('test/foo_test.rb')).to be true
      expect(described_class.test_file?('test/test_foo.rb')).to be true
    end

    it 'recognizes an unconventionally named minitest file by its content' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'checks.rb')
        File.write(path, "require 'minitest/autorun'\n")
        expect(described_class.test_file?(path)).to be true
      end
    end

    it 'treats a plain source file as not a test file' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'plain.rb')
        File.write(path, "class Plain\nend\n")
        expect(described_class.test_file?(path)).to be false
      end
    end

    it 'does not classify names by loose suffix accidents' do
      expect(described_class.test_file?('lib/latest.rb')).to be false
      expect(described_class.test_file?('lib/attest.rb')).to be false
      expect(described_class.test_file?('lib/inspect.rb')).to be false
    end
  end

  describe '#classify for an explicit file list' do
    around do |example|
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) { example.run }
      end
    end

    it 'skips a nonexistent file with a file-not-found reason' do
      entry = list_runner(['lib/gone.rb']).classify('lib/gone.rb')
      expect(entry.reason).to eq(:missing)
      expect(entry.source_file).to eq('lib/gone.rb')
    end

    it 'skips a non-Ruby file' do
      File.write('notes.md', "# notes\n")
      entry = list_runner(['notes.md']).classify('notes.md')
      expect(entry.reason).to eq(:not_ruby)
    end

    it 'skips a test file passed directly' do
      FileUtils.mkdir_p('spec')
      File.write('spec/foo_spec.rb', "RSpec.describe('x') {}\n")
      entry = list_runner(['spec/foo_spec.rb']).classify('spec/foo_spec.rb')
      expect(entry.reason).to eq(:test_file)
    end

    it 'skips a source without a conventional spec, naming the expected path' do
      FileUtils.mkdir_p('lib')
      File.write('lib/orphan.rb', "class Orphan\nend\n")
      entry = list_runner(['lib/orphan.rb']).classify('lib/orphan.rb')
      expect(entry.reason).to eq(:no_spec)
      expect(entry.expected_spec).to eq('spec/orphan_spec.rb')
    end

    it 'returns the mapped spec path for a mutable source, honouring the template' do
      FileUtils.mkdir_p('lib')
      FileUtils.mkdir_p('test')
      File.write('lib/adder.rb', "class Adder\nend\n")
      File.write('test/adder_test.rb', "require 'minitest/autorun'\n")

      expect(list_runner(['lib/adder.rb'], spec_template: 'test/{name}_test.rb').classify('lib/adder.rb'))
        .to eq('test/adder_test.rb')
    end
  end

  describe 'list mode run with only skipped files' do
    it 'reports every skip reason, processes nothing, and flags the empty run' do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          FileUtils.mkdir_p('lib')
          File.write('notes.md', "# notes\n")
          File.write('foo_spec.rb', "RSpec.describe('x') {}\n")
          File.write('lib/orphan.rb', "class Orphan\nend\n")

          runner = list_runner(['lib/gone.rb', 'notes.md', 'foo_spec.rb', 'lib/orphan.rb'])
          result = nil
          expect { result = runner.run }.to output(
            /SKIPPED \(file not found\):.*SKIPPED \(not a Ruby source file\):.*SKIPPED \(a test file, not a mutable source\):.*SKIPPED \(no matching spec file\):.*No files were mutation-tested: every listed file was skipped/m
          ).to_stdout

          expect(result.processed).to be_empty
          expect(result.skipped.map(&:reason)).to contain_exactly(:missing, :not_ruby, :test_file, :no_spec)
        end
      end
    end
  end

  describe '.staged_files' do
    def commit_all(dir)
      system('git', '-C', dir, 'add', '-A')
      system('git', '-C', dir, '-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-q', '-m', 'baseline')
    end

    it 'lists staged new and modified files relative to the given directory' do
      Dir.mktmpdir do |dir|
        system('git', '-C', dir, 'init', '-q')
        File.write(File.join(dir, 'tracked.rb'), "1\n")
        commit_all(dir)

        File.write(File.join(dir, 'tracked.rb'), "2\n")
        File.write(File.join(dir, 'brand_new.rb'), "3\n")
        File.write(File.join(dir, 'unstaged.rb'), "4\n")
        system('git', '-C', dir, 'add', 'tracked.rb', 'brand_new.rb')

        expect(described_class.staged_files(dir: dir)).to contain_exactly('brand_new.rb', 'tracked.rb')
      end
    end

    it 'filters out files staged as deleted' do
      Dir.mktmpdir do |dir|
        system('git', '-C', dir, 'init', '-q')
        File.write(File.join(dir, 'doomed.rb'), "1\n")
        File.write(File.join(dir, 'kept.rb'), "1\n")
        commit_all(dir)

        File.write(File.join(dir, 'kept.rb'), "2\n")
        system('git', '-C', dir, 'add', 'kept.rb')
        system('git', '-C', dir, 'rm', '-q', 'doomed.rb')

        expect(described_class.staged_files(dir: dir)).to eq(['kept.rb'])
      end
    end

    it 'raises a readable error outside a git repository' do
      Dir.mktmpdir do |dir|
        expect { described_class.staged_files(dir: dir) }
          .to raise_error(MutationTester::Error, /not a git repository/)
      end
    end
  end

  describe 'source->spec mapping' do
    it 'applies the default lib/X.rb -> spec/X_spec.rb convention, preserving subdirectories' do
      runner = build_runner
      expect(runner.send(:spec_path_for, 'lib/foo.rb')).to eq('spec/foo_spec.rb')
      expect(runner.send(:spec_path_for, 'lib/foo/bar.rb')).to eq('spec/foo/bar_spec.rb')
    end

    it 'strips only a leading lib/ segment (a non-lib source keeps its path under spec/)' do
      runner = build_runner
      expect(runner.send(:spec_path_for, 'app/models/user.rb')).to eq('spec/app/models/user_spec.rb')
    end

    it 'honours a --spec-glob template via the {name} placeholder' do
      runner = build_runner(spec_template: 'test/{name}_test.rb')
      expect(runner.send(:spec_path_for, 'lib/foo/bar.rb')).to eq('test/foo/bar_test.rb')
    end

    it 'falls back to the default convention for a nil or empty template' do
      expect(build_runner(spec_template: nil).send(:spec_path_for, 'lib/foo.rb')).to eq('spec/foo_spec.rb')
      expect(build_runner(spec_template: '').send(:spec_path_for, 'lib/foo.rb')).to eq('spec/foo_spec.rb')
    end
  end

  describe 'per-file report subdirectory' do
    it 'nests a flat, collision-free slug directly under the base output_dir' do
      config.output_dir = 'tmp/mutation_reports'
      runner = build_runner

      sub_a = runner.send(:report_subdir_for, 'lib/foo/bar.rb')
      sub_b = runner.send(:report_subdir_for, 'lib/foo/baz.rb')

      expect(File.dirname(sub_a)).to eq('tmp/mutation_reports')
      expect(File.basename(sub_a)).not_to include('/')

      expect(sub_a).not_to eq(sub_b)
    end

    it 'maps sources whose slugs alone would collide to distinct directories' do
      config.output_dir = 'tmp/mutation_reports'
      runner = build_runner

      sub_nested = runner.send(:report_subdir_for, 'lib/foo/bar.rb')
      sub_flat = runner.send(:report_subdir_for, 'lib/foo_bar.rb')

      expect(sub_nested).not_to eq(sub_flat)
      [sub_nested, sub_flat].each do |sub|
        expect(File.dirname(sub)).to eq('tmp/mutation_reports')
        expect(File.basename(sub)).not_to include('/')
      end
    end

    it 'never produces a .. segment that could escape output_dir' do
      runner = build_runner
      subdir = runner.send(:report_subdir_for, '../../etc/passwd.rb')
      expect(subdir).not_to include('..')
    end
  end

  describe '.changed_files_since' do
    def init_repo(dir)
      system('git', '-C', dir, 'init', '-q')
      system('git', '-C', dir, '-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-q', '--allow-empty', '-m', 'init')
    end

    it 'returns absolute paths for files modified since the revision and for new untracked files' do
      Dir.mktmpdir do |dir|
        init_repo(dir)
        File.write(File.join(dir, 'tracked.rb'), "1\n")
        system('git', '-C', dir, 'add', 'tracked.rb')
        system('git', '-C', dir, '-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-q', '-m', 'add tracked')
        File.write(File.join(dir, 'tracked.rb'), "2\n")
        File.write(File.join(dir, 'brand_new.rb'), "3\n")

        changed = described_class.changed_files_since('HEAD', dir: dir)

        expect(changed).to include(File.join(File.realpath(dir), 'tracked.rb'))
        expect(changed).to include(File.join(File.realpath(dir), 'brand_new.rb'))
      end
    end

    it 'excludes files that did not change since the revision' do
      Dir.mktmpdir do |dir|
        init_repo(dir)
        File.write(File.join(dir, 'stable.rb'), "1\n")
        system('git', '-C', dir, 'add', 'stable.rb')
        system('git', '-C', dir, '-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-q', '-m', 'add stable')

        expect(described_class.changed_files_since('HEAD', dir: dir)).to be_empty
      end
    end

    it 'raises a readable error for an unknown revision' do
      Dir.mktmpdir do |dir|
        init_repo(dir)
        expect { described_class.changed_files_since('no-such-rev', dir: dir) }
          .to raise_error(MutationTester::Error, /unknown revision "no-such-rev"/)
      end
    end

    it 'raises a readable error outside a git repository' do
      Dir.mktmpdir do |dir|
        expect { described_class.changed_files_since('HEAD', dir: dir) }
          .to raise_error(MutationTester::Error, /not a git repository/)
      end
    end

    it 'treats a missing git executable like a missing repository' do
      allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)
      expect { described_class.changed_files_since('HEAD', dir: '/') }
        .to raise_error(MutationTester::Error, /git executable not found/)
    end
  end

  describe 'filtering matched sources by the changed set' do
    it 'keeps only sources whose absolute path is in the changed set and reports the rest as unchanged' do
      changed = Set.new([File.expand_path('lib/foo.rb')])
      runner = build_runner(changed_files: changed)

      kept, unchanged = runner.send(:partition_by_change, ['lib/foo.rb', 'lib/bar.rb'])

      expect(kept).to eq(['lib/foo.rb'])
      expect(unchanged).to eq(['lib/bar.rb'])
    end

    it 'keeps every source when no changed set was given' do
      kept, unchanged = build_runner.send(:partition_by_change, ['lib/foo.rb', 'lib/bar.rb'])
      expect(kept).to eq(['lib/foo.rb', 'lib/bar.rb'])
      expect(unchanged).to eq([])
    end
  end

  describe MutationTester::BatchRunner::Result do
    def processed(passed)
      MutationTester::BatchRunner::ProcessedEntry.new(
        source_file: 'lib/x.rb', spec_file: 'spec/x_spec.rb',
        score: passed ? 100.0 : 0.0, passed: passed, output_dir: 'tmp/x'
      )
    end

    def skipped
      MutationTester::BatchRunner::SkippedEntry.new(source_file: 'lib/y.rb', expected_spec: 'spec/y_spec.rb')
    end

    it 'succeeds only when every processed file met the threshold' do
      expect(described_class.new(processed: [processed(true), processed(true)], skipped: []).success?).to be true
      expect(described_class.new(processed: [processed(true), processed(false)], skipped: []).success?).to be false
    end

    it 'treats a skipped file as non-fatal: a batch that only skipped files still succeeds' do
      result = described_class.new(processed: [], skipped: [skipped])
      expect(result.success?).to be true
      expect(result.matched_any?).to be true
    end

    it 'reports matched_any? false only when nothing was matched at all' do
      expect(described_class.new(processed: [], skipped: []).matched_any?).to be false
      expect(described_class.new(processed: [processed(true)], skipped: []).matched_any?).to be true
    end

    it 'treats a run where every match was unchanged as matched and successful' do
      result = described_class.new(processed: [], skipped: [], unchanged: ['lib/z.rb'])
      expect(result.matched_any?).to be true
      expect(result.success?).to be true
      expect(result.interrupted?).to be false
    end

    def entry_with_results(source, results)
      MutationTester::BatchRunner::ProcessedEntry.new(
        source_file: source, spec_file: 'spec/x_spec.rb',
        score: 0.0, passed: false, output_dir: 'tmp/x', results: results, interrupted: false
      )
    end

    describe '#survivors' do
      it 'flattens surviving mutants across files into file/line/type/original/mutated entries' do
        result = described_class.new(
          processed: [
            entry_with_results('lib/a.rb', [
              { id: 1, status: :killed, line: 1, type: :boolean, original: 'true', mutated: 'false' },
              { id: 2, status: :survived, line: 4, type: :arithmetic, original: '+', mutated: '-',
                source_line: 'a + b', mutated_line: 'a - b', file_path: '/abs/lib/a.rb', kill_phase: :full }
            ]),
            entry_with_results('lib/b.rb', [
              { id: 1, status: :survived, line: 9, type: :comparison, original: '>', mutated: '<' }
            ])
          ],
          skipped: []
        )

        expect(result.survivors).to eq([
          { file: 'lib/a.rb', line: 4, type: :arithmetic, original: '+', mutated: '-' },
          { file: 'lib/b.rb', line: 9, type: :comparison, original: '>', mutated: '<' }
        ])
      end

      it 'excludes timeout, stillborn and error mutants and tolerates entries without results' do
        result = described_class.new(
          processed: [
            entry_with_results('lib/a.rb', [
              { id: 1, status: :timeout, line: 1, type: :arithmetic, original: '*', mutated: '/' },
              { id: 2, status: :stillborn, line: 2, type: :arithmetic, original: '-', mutated: '+' },
              { id: 3, status: :error, line: 3, type: :arithmetic, original: '/', mutated: '*' }
            ]),
            processed(true)
          ],
          skipped: []
        )

        expect(result.survivors).to eq([])
      end
    end
  end

  describe 'survivors section in the batch summary' do
    def result_with_survivor
      MutationTester::BatchRunner::Result.new(
        processed: [
          MutationTester::BatchRunner::ProcessedEntry.new(
            source_file: 'lib/calc.rb', spec_file: 'spec/calc_spec.rb',
            score: 50.0, passed: false, output_dir: 'tmp/calc',
            results: [
              { id: 1, status: :killed, line: 1, type: :boolean, original: 'true', mutated: 'false' },
              { id: 2, status: :survived, line: 4, type: :arithmetic, original: '+', mutated: '-' }
            ],
            interrupted: false
          )
        ],
        skipped: []
      )
    end

    it 'ends the summary with one line per surviving mutant plus a plain explanation' do
      runner = list_runner(['lib/calc.rb'])
      output = capture_summary(runner, result_with_survivor)

      expect(output).to match(/Surviving mutants \(1\):.*lib\/calc\.rb:4 \+ -> -/m)
      expect(output).to include('A surviving mutant is a change to your code that your tests do not detect')
      expect(output.index('Surviving mutants')).to be > output.index('mutation score threshold')
    end

    it 'omits the survivors section entirely when every mutant was killed' do
      runner = list_runner(['lib/calc.rb'])
      result = result_with_survivor
      result.processed.first.results = [
        { id: 1, status: :killed, line: 1, type: :boolean, original: 'true', mutated: 'false' }
      ]

      output = capture_summary(runner, result)

      expect(output).not_to include('Surviving mutants')
      expect(output).not_to include('A surviving mutant is')
    end

    def capture_summary(runner, result)
      captured = StringIO.new
      original = $stdout
      $stdout = captured
      begin
        runner.send(:print_summary, result)
      ensure
        $stdout = original
      end
      captured.string
    end
  end
end
