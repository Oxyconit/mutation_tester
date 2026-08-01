require 'spec_helper'

RSpec.describe MutationTester::Reporters::ConsoleReporter do
  let(:config) { MutationTester::Configuration.new }
  let(:results) do
    [
      { id: 1, killed: true, line: 10, type: :arithmetic, description: 'Change + to -' },
      { id: 2, killed: false, line: 20, type: :boolean, description: 'Change true to false', original: 'true', mutated: 'false', file_path: 'lib/foo.rb' }
    ]
  end
  let(:reporter) { described_class.new(results, 'lib/foo.rb', 'spec/foo_spec.rb', config) }

  before do
    Rainbow.enabled = false
  end

  after do
    Rainbow.enabled = true
  end

  describe '#generate' do
    it 'prints summary and survived mutations' do
      output = capture_stdout { reporter.generate }

      expect(output).to include('MUTATION TESTING REPORT')
      expect(output).to include('Total Mutations: 2')
      expect(output).to include('Killed: 1')
      expect(output).to include('Survived: 1')
      expect(output).to include('Mutation Score: 50.0%')
      expect(output).to include('Survived Mutations')
      expect(output).to include('#2 [boolean] Change true to false')
      expect(output).to include('Location: lib/foo.rb:20')
    end

    context 'when all mutations are killed' do
      let(:results) do
        [{ id: 1, killed: true, line: 10, type: :arithmetic, description: 'Change + to -' }]
      end

      it 'does not print survived mutations section' do
        output = capture_stdout { reporter.generate }

        expect(output).to include('Total Mutations: 1')
        expect(output).not_to include('Survived Mutations')
      end
    end

    context 'with every status category present' do
      let(:results) do
        [
          { id: 1, status: :killed, killed: true, line: 1, type: :arithmetic, description: 'k' },
          { id: 2, status: :survived, killed: false, line: 2, type: :boolean, description: 's' },
          { id: 3, status: :timeout, killed: true, timeout: true, line: 3, type: :arithmetic, description: 't' },
          { id: 4, status: :stillborn, killed: false, line: 4, type: :arithmetic, description: 'sb' },
          { id: 5, status: :error, killed: false, line: 5, type: :arithmetic, description: 'e' }
        ]
      end

      it 'prints a counter for each category and a score that ignores stillborn/error' do
        output = capture_stdout { reporter.generate }

        expect(output).to include('Total Mutations: 5')
        expect(output).to include('Killed: 1')
        expect(output).to include('Survived: 1')
        expect(output).to include('Timeout: 1')
        expect(output).to include('Stillborn: 1')
        expect(output).to include('Errors: 1')
        expect(output).to include('Mutation Score: 66.67%')
        expect(output).to include('Quality: Fair')
      end
    end

    context 'with mutants that ran into the deadline' do
      let(:results) do
        [
          { id: 1, status: :killed, killed: true, line: 1, type: :arithmetic, description: 'k' },
          { id: 2, status: :timeout, killed: true, timeout: true, line: 2, type: :arithmetic, description: 't' }
        ]
      end

      it 'names the deadline the mutants were measured against and the baseline it came from' do
        config.timeout_factor = 5
        config.baseline_duration = 1.3

        output = capture_stdout { reporter.generate }

        expect(output).to include('deadline: 6.50s (5x baseline 1.30s)')
      end

      it 'keeps the calibration floor visible when the baseline is fast' do
        config.timeout_factor = 5
        config.baseline_duration = 0.2

        output = capture_stdout { reporter.generate }

        expect(output).to include('deadline: 5.00s')
      end

      it 'says the deadline was configured by hand instead of inventing a baseline multiple' do
        config.timeout = 30
        config.baseline_duration = 1.3

        output = capture_stdout { reporter.generate }

        expect(output).to include('deadline: 30.00s (explicitly configured)')
      end
    end

    context 'with no mutant that ran into the deadline' do
      let(:results) do
        [{ id: 1, status: :killed, killed: true, line: 1, type: :arithmetic, description: 'k' }]
      end

      it 'prints no deadline line at all' do
        config.baseline_duration = 1.3

        expect(capture_stdout { reporter.generate }).not_to include('deadline:')
      end
    end

    context 'with kill phases recorded by two-phase test selection' do
      let(:results) do
        [
          { id: 1, status: :killed, killed: true, kill_phase: :subset, line: 1, type: :arithmetic, description: 'k1' },
          { id: 2, status: :timeout, killed: true, timeout: true, kill_phase: :subset, line: 2, type: :arithmetic, description: 'k2' },
          { id: 3, status: :killed, killed: true, kill_phase: :full, line: 3, type: :boolean, description: 'k3' }
        ]
      end

      it 'prints how many kills came from the subset and how many from the full file' do
        output = capture_stdout { reporter.generate }

        expect(output).to include('Selection: 2 kill(s) by test subset, 1 by full file')
      end

      context 'when test selection is disabled' do
        let(:config) do
          MutationTester::Configuration.new.tap { |c| c.test_selection = false }
        end

        it 'does not print the selection line' do
          output = capture_stdout { reporter.generate }

          expect(output).not_to include('Selection:')
        end
      end

      context 'when the test file is minitest' do
        let(:reporter) { described_class.new(results, 'lib/foo.rb', 'test/foo_test.rb', config) }

        it 'does not print the selection line' do
          output = capture_stdout { reporter.generate }

          expect(output).not_to include('Selection:')
        end
      end
    end

    context 'with selection enabled but no kills' do
      let(:results) do
        [{ id: 1, status: :survived, killed: false, line: 2, type: :boolean, description: 's', original: 'true', mutated: 'false', file_path: 'lib/foo.rb' }]
      end

      it 'prints the selection line with zero counts' do
        output = capture_stdout { reporter.generate }

        expect(output).to include('Selection: 0 kill(s) by test subset, 0 by full file')
      end
    end

    context 'with the in-memory runner' do
      let(:config) do
        MutationTester::Configuration.new.tap { |c| c.runner = :in_memory }
      end
      let(:results) do
        [
          { id: 1, status: :killed, killed: true, line: 1, type: :arithmetic, description: 'k1' },
          { id: 2, status: :survived, killed: false, line: 2, type: :boolean, description: 's', original: 'true', mutated: 'false', file_path: 'lib/foo.rb' }
        ]
      end

      it 'does not print the selection line because no test selection ran' do
        output = capture_stdout { reporter.generate }

        expect(output).not_to include('Selection:')
      end

      context 'when a fallback executed mutants through the file-based path' do
        let(:results) do
          [
            { id: 1, status: :killed, killed: true, line: 1, type: :arithmetic, description: 'k1' },
            { id: 2, status: :killed, killed: true, kill_phase: :subset, line: 2, type: :arithmetic, description: 'k2' }
          ]
        end

        it 'prints the selection counts recorded by the fallback' do
          output = capture_stdout { reporter.generate }

          expect(output).to include('Selection: 1 kill(s) by test subset, 0 by full file')
        end
      end
    end

    context 'with show_file_path disabled' do
      let(:config) do
        MutationTester::Configuration.new.tap { |c| c.show_file_path = false }
      end
      let(:results) do
        [
          {
            id: 7, status: :survived, killed: false, line: 42, type: :boolean,
            description: 'Change true to false',
            file_path: 'lib/foo.rb', original: 'true', mutated: 'false'
          }
        ]
      end

      it 'prints "Line: N" without the file path' do
        output = capture_stdout { reporter.generate }

        expect(output).to include('Line: 42')
        expect(output).not_to include('Location:')
        expect(output).not_to include('lib/foo.rb')
      end
    end

    context 'when a survived mutation carries source_line and mutated_line' do
      let(:results) do
        [
          {
            id: 8, status: :survived, killed: false, line: 3, type: :boolean,
            description: 'Change true to false',
            source_line: 'flag = true', mutated_line: 'flag = false'
          }
        ]
      end

      it 'renders the diff as - and + lines and omits the Original/Mutated fallback' do
        output = capture_stdout { reporter.generate }

        expect(output).to include('- flag = true')
        expect(output).to include('+ flag = false')
        expect(output).not_to include('Original:')
        expect(output).not_to include('Mutated:')
      end
    end

    context 'when the source file is readable and matches the reported line' do
      require 'tmpdir'

      let(:tmp_dir) { Dir.mktmpdir }
      let(:source_path) { File.join(tmp_dir, 'calc.rb') }
      let(:reporter) { described_class.new(results, source_path, 'spec/foo_spec.rb', config) }
      let(:results) do
        [
          {
            id: 3, status: :survived, killed: false, line: 3, type: :math,
            description: 'Change + to -',
            source_line: 'a + b', mutated_line: 'a - b',
            file_path: source_path
          }
        ]
      end

      before do
        File.write(source_path, <<~RUBY)
          class Calc
            def add(a, b)
              a + b
            end
          end
        RUBY
      end

      after do
        FileUtils.remove_entry(tmp_dir)
      end

      it 'prints a unified diff with a hunk header, context lines and -/+ markers' do
        output = capture_stdout { reporter.generate }

        expect(output).to include('@@ -1,5 +1,5 @@')
        expect(output).to include('  def add(a, b)')
        expect(output).to include('-     a + b')
        expect(output).to include('+     a - b')
        expect(output).to include('  end')
      end
    end

    context 'with several survivors at the same file and line' do
      let(:results) do
        [
          {
            id: 4, status: :survived, killed: false, line: 12, type: :math,
            description: 'Change + to -', file_path: 'lib/foo.rb',
            source_line: 'a + b', mutated_line: 'a - b'
          },
          {
            id: 5, status: :survived, killed: false, line: 12, type: :math,
            description: 'Change + to *', file_path: 'lib/foo.rb',
            source_line: 'a + b', mutated_line: 'a * b'
          },
          {
            id: 6, status: :survived, killed: false, line: 30, type: :boolean,
            description: 'Change true to false', file_path: 'lib/foo.rb',
            source_line: 'flag = true', mutated_line: 'flag = false'
          }
        ]
      end

      it 'prints the location header once per group with the variant count' do
        output = capture_stdout { reporter.generate }

        expect(output.scan('Location: lib/foo.rb:12').size).to eq(1)
        expect(output).to include('Location: lib/foo.rb:12 (2 variants)')
        expect(output).to include('Location: lib/foo.rb:30')
        expect(output).not_to include('lib/foo.rb:30 (')
      end

      it 'lists each variant with type and description under the group header' do
        output = capture_stdout { reporter.generate }

        expect(output).to include('#4 [math] Change + to -')
        expect(output).to include('#5 [math] Change + to *')
        expect(output).to include('#6 [boolean] Change true to false')
      end

      it 'renders one removed line and one added line per variant tagged with its id' do
        output = capture_stdout { reporter.generate }

        expect(output.scan('- a + b').size).to eq(1)
        expect(output).to include('+ a - b  (#4)')
        expect(output).to include('+ a * b  (#5)')
      end

      it 'orders groups by line number' do
        output = capture_stdout { reporter.generate }

        expect(output.index('lib/foo.rb:12')).to be < output.index('lib/foo.rb:30')
      end
    end
  end

  def capture_stdout
    original_stdout = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original_stdout
  end
end
