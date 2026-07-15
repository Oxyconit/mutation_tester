require 'spec_helper'
require 'tmpdir'

RSpec.describe MutationTester::Reporters::BaseReporter do
  let(:config) { MutationTester::Configuration.new }

  def reporter_for(results)
    MutationTester::Reporters::ConsoleReporter.new(results, 'lib/foo.rb', 'spec/foo_spec.rb', config)
  end

  describe '#quality_rating' do
    {
      95.0 => 'Excellent 🌟',
      90 => 'Excellent 🌟',
      89.5 => 'Good 👍',
      75 => 'Good 👍',
      74.29 => 'Fair 😐',
      60 => 'Fair 😐',
      59.5 => 'Poor 😟',
      40 => 'Poor 😟',
      39.9 => 'Critical ⚠️',
      0.0 => 'Critical ⚠️'
    }.each do |score, expected|
      it "maps #{score} to #{expected}" do
        reporter = reporter_for([])
        allow(reporter).to receive(:mutation_score).and_return(score)

        expect(reporter.send(:quality_rating)).to eq(expected)
      end
    end
  end

  describe 'category counters and score' do
    let(:results) do
      [
        { id: 1, status: :killed, killed: true },
        { id: 2, status: :killed, killed: true },
        { id: 3, status: :survived, killed: false },
        { id: 4, status: :timeout, killed: true, timeout: true },
        { id: 5, status: :stillborn, killed: false },
        { id: 6, status: :error, killed: false, description: 'Error: boom' }
      ]
    end
    let(:reporter) { reporter_for(results) }

    it 'counts each category and they sum to the total' do
      expect(reporter.send(:total_count)).to eq(6)
      expect(reporter.send(:killed_count)).to eq(2)
      expect(reporter.send(:survived_count)).to eq(1)
      expect(reporter.send(:timeout_count)).to eq(1)
      expect(reporter.send(:stillborn_count)).to eq(1)
      expect(reporter.send(:error_count)).to eq(1)

      categories = %i[killed_count survived_count timeout_count stillborn_count error_count]
      expect(categories.sum { |m| reporter.send(m) }).to eq(reporter.send(:total_count))
    end

    it 'excludes stillborn and error from the score and counts timeout as killed' do
      expect(reporter.send(:mutation_score)).to eq(75.0)
      expect(reporter.send(:effective_killed_count)).to eq(3)
    end
  end

  describe '.score under the separate timeout policy' do
    let(:results) do
      [
        { id: 1, status: :killed, killed: true },
        { id: 2, status: :killed, killed: true },
        { id: 3, status: :survived, killed: false },
        { id: 4, status: :timeout, killed: true, timeout: true },
        { id: 5, status: :timeout, killed: true, timeout: true },
        { id: 6, status: :timeout, killed: true, timeout: true },
        { id: 7, status: :stillborn, killed: false },
        { id: 8, status: :error, killed: false, description: 'Error: boom' }
      ]
    end

    it 'scores killed / (killed + survived), leaving timeouts out of numerator and denominator' do
      expect(described_class.score(results, policy: :separate)).to eq(66.67)
      expect(described_class.score(results, policy: :killed)).to eq(83.33)
      expect(described_class.score(results)).to eq(83.33)
    end

    it 'does not let load-induced timeouts raise the score, unlike the default policy' do
      base = [
        { id: 1, status: :killed, killed: true },
        { id: 2, status: :survived, killed: false }
      ]
      under_load = base + [
        { id: 3, status: :timeout, killed: true, timeout: true },
        { id: 4, status: :timeout, killed: true, timeout: true }
      ]

      idle_score = described_class.score(base, policy: :separate)
      loaded_score = described_class.score(under_load, policy: :separate)

      expect(loaded_score).to eq(idle_score)
      expect(described_class.score(under_load, policy: :killed)).to be > idle_score
    end

    it 'returns 0.0 when nothing was killed or survived' do
      only_timeouts = [{ id: 1, status: :timeout, killed: true, timeout: true }]

      expect(described_class.score(only_timeouts, policy: :separate)).to eq(0.0)
    end

    it 'drives the instance score and effective kills through config.timeout_policy' do
      config.timeout_policy = :separate
      reporter = reporter_for(results)

      expect(reporter.send(:mutation_score)).to eq(66.67)
      expect(reporter.send(:effective_killed_count)).to eq(2)
      expect(reporter.send(:timeout_count)).to eq(3)
    end
  end

  describe 'removed dead helpers' do
    %i[killed_mutations scored_count].each do |method_name|
      it "no longer defines ##{method_name}" do
        expect(described_class.method_defined?(method_name)).to be(false)
        expect(described_class.private_method_defined?(method_name)).to be(false)
      end
    end
  end

  describe '#survivor_groups' do
    let(:results) do
      [
        { id: 1, status: :killed, killed: true, line: 5, file_path: 'lib/foo.rb' },
        { id: 2, status: :survived, killed: false, line: 30, file_path: 'lib/foo.rb' },
        { id: 3, status: :survived, killed: false, line: 12, file_path: 'lib/foo.rb' },
        { id: 4, status: :survived, killed: false, line: 12, file_path: 'lib/foo.rb' },
        { id: 5, status: :timeout, killed: true, timeout: true, line: 12, file_path: 'lib/foo.rb' }
      ]
    end

    it 'groups only survivors by file and line, ordered by line' do
      groups = reporter_for(results).send(:survivor_groups)

      expect(groups.map { |g| g[:line] }).to eq([12, 30])
      expect(groups.first[:mutations].map { |m| m[:id] }).to eq([3, 4])
      expect(groups.last[:mutations].map { |m| m[:id] }).to eq([2])
    end
  end

  describe '#diff_lines' do
    let(:tmp_dir) { Dir.mktmpdir }
    let(:source_path) { File.join(tmp_dir, 'calc.rb') }

    after do
      FileUtils.remove_entry(tmp_dir)
    end

    def write_source
      File.write(source_path, <<~RUBY)
        class Calc
          def add(a, b)
            a + b
          end
        end
      RUBY
    end

    def mutation(overrides = {})
      {
        id: 1, status: :survived, killed: false, line: 3, type: :math,
        description: 'Change + to -', file_path: source_path,
        source_line: 'a + b', mutated_line: 'a - b'
      }.merge(overrides)
    end

    it 'builds a hunk with context lines around the change and re-indented -/+ lines' do
      write_source
      lines = reporter_for([]).send(:diff_lines, [mutation])

      expect(lines).to eq(
        [
          [:hunk, '@@ -1,5 +1,5 @@', nil],
          [:context, 'class Calc', nil],
          [:context, '  def add(a, b)', nil],
          [:removed, '    a + b', nil],
          [:added, '    a - b', mutation],
          [:context, '  end', nil],
          [:context, 'end', nil]
        ]
      )
    end

    it 'emits one added line per variant inside a shared hunk' do
      write_source
      variants = [mutation, mutation(id: 2, mutated_line: 'a * b')]
      lines = reporter_for([]).send(:diff_lines, variants)

      expect(lines.count { |kind, _, _| kind == :removed }).to eq(1)
      added = lines.select { |kind, _, _| kind == :added }
      expect(added.map { |_, text, _| text }).to eq(['    a - b', '    a * b'])
      expect(added.map { |_, _, variant| variant[:id] }).to eq([1, 2])
      expect(lines.first).to eq([:hunk, '@@ -1,5 +1,6 @@', nil])
    end

    it 'falls back to a context-free -/+ pair when the source file is unreadable' do
      lines = reporter_for([]).send(:diff_lines, [mutation(file_path: File.join(tmp_dir, 'missing.rb'))])

      expect(lines).to eq([[:removed, 'a + b', nil], [:added, 'a - b', mutation(file_path: File.join(tmp_dir, 'missing.rb'))]])
    end

    it 'falls back when the on-disk line no longer matches the recorded source line' do
      write_source
      stale = mutation(source_line: 'something_else')
      lines = reporter_for([]).send(:diff_lines, [stale])

      expect(lines).to eq([[:removed, 'something_else', nil], [:added, 'a - b', stale]])
    end

    it 'falls back to original/mutated when no source_line was recorded' do
      raw = mutation(source_line: nil, mutated_line: nil, original: '+', mutated: '-')
      lines = reporter_for([]).send(:diff_lines, [raw])

      expect(lines).to eq([[:removed, '+', nil], [:added, '-', raw]])
    end
  end

  describe 'single source of truth for mutation_score' do
    let(:mixed_results) do
      [
        { id: 1, status: :killed, killed: true },
        { id: 2, status: :killed, killed: true },
        { id: 3, status: :killed, killed: true },
        { id: 4, status: :timeout, killed: true, timeout: true },
        { id: 5, status: :survived, killed: false },
        { id: 6, status: :survived, killed: false },
        { id: 7, status: :stillborn, killed: false },
        { id: 8, status: :error, killed: false, description: 'Error: boom' }
      ]
    end

    def core_for(results)
      dir = Dir.mktmpdir
      source = File.join(dir, 'src.rb')
      spec = File.join(dir, 'src_spec.rb')
      File.write(source, "x = 1\n")
      File.write(spec, '')
      core = MutationTester::Core.new(source, spec, config)
      core.instance_variable_set(:@results, results)
      core
    end

    it 'gives Core and BaseReporter the identical (killed+timeout)/(killed+timeout+survived) score' do
      expected = (4.0 / 6 * 100).round(2)
      expect(expected).to eq(66.67)

      core_score = core_for(mixed_results).mutation_score
      reporter_score = reporter_for(mixed_results).send(:mutation_score)
      shared_score = MutationTester::Reporters::BaseReporter.score(mixed_results)

      expect(core_score).to eq(66.67)
      expect(reporter_score).to eq(66.67)
      expect(shared_score).to eq(66.67)
      expect(core_score).to eq(reporter_score)
    end
  end
end
