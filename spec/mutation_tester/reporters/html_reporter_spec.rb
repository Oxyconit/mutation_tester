require 'spec_helper'
require 'tmpdir'

RSpec.describe MutationTester::Reporters::HtmlReporter do
  let(:tmp_dir) { Dir.mktmpdir }
  let(:config) do
    MutationTester::Configuration.new.tap do |c|
      c.output_dir = tmp_dir
    end
  end
  let(:results) do
    [
      { id: 1, killed: true, line: 10, type: :arithmetic, description: 'Change + to -' },
      { id: 2, killed: false, line: 20, type: :boolean, description: 'Change true to false', original: 'true', mutated: 'false', file_path: 'lib/foo.rb' }
    ]
  end
  let(:reporter) { described_class.new(results, 'lib/foo.rb', 'spec/foo_spec.rb', config) }

  after do
    FileUtils.remove_entry(tmp_dir)
  end

  describe '#generate' do
    it 'creates an HTML report file' do
      expect { reporter.generate }.to output(/HTML report saved to/).to_stdout

      report_path = File.join(tmp_dir, 'mutation_report.html')
      expect(File.exist?(report_path)).to be true

      content = File.read(report_path)
      expect(content).to include('Mutation Report')
      expect(content).to include('Total Mutations</div>')
      expect(content).to include('>2</div>')
      expect(content).to include('>1</div>')
      expect(content).to include('>50.0%</div>')
      expect(content).to include('Change true to false')
    end

    context 'with the full status taxonomy' do
      let(:results) do
        [
          { id: 1, status: :killed, killed: true, line: 1, type: :arithmetic, description: 'k' },
          { id: 2, status: :survived, killed: false, line: 2, type: :boolean, description: 'survived here' },
          { id: 3, status: :timeout, killed: true, timeout: true, line: 3, type: :arithmetic, description: 't' },
          { id: 4, status: :stillborn, killed: false, line: 4, type: :arithmetic, description: 'sb' },
          { id: 5, status: :error, killed: false, line: 5, type: :arithmetic, description: 'e' }
        ]
      end

      it 'renders category chips and per-mutant status badges' do
        reporter.generate
        content = File.read(File.join(tmp_dir, 'mutation_report.html'))

        %w[Killed Survived Timeout Stillborn Error].each do |label|
          expect(content).to include(label)
        end

        expect(content).to include('data-status="timeout"')
        expect(content).to include('data-status="stillborn"')
        expect(content).to include('data-status="error"')
        expect(content).to include('status-timeout')
      end
    end

    context 'with HTML-unsafe source content' do
      let(:reporter) do
        described_class.new(results, 'lib/<svg onload=alert(1)>.rb', 'spec/foo_spec.rb', config)
      end
      let(:results) do
        [
          {
            id: 1, status: :survived, killed: false, line: 7, type: :boolean,
            description: '<img src=x onerror=alert(2)>',
            source_line: '<script>alert(1)</script>',
            mutated_line: '<script>alert(3)</script>',
            file_path: 'lib/<b>foo</b>.rb'
          }
        ]
      end

      it 'escapes injected markup so raw tags never reach the report' do
        reporter.generate
        content = File.read(File.join(tmp_dir, 'mutation_report.html'))

        expect(content).to include('&lt;script&gt;alert(1)&lt;/script&gt;')
        expect(content).to include('&lt;img src=x onerror=alert(2)&gt;')
        expect(content).not_to include('<script>alert(1)</script>')
        expect(content).not_to include('<img src=x onerror=alert(2)>')
      end

      it 'escapes the header source file path and the per-mutant file path' do
        reporter.generate
        content = File.read(File.join(tmp_dir, 'mutation_report.html'))

        expect(content).to include('lib/&lt;svg onload=alert(1)&gt;.rb')
        expect(content).to include('lib/&lt;b&gt;foo&lt;/b&gt;.rb')
        expect(content).not_to include('lib/<svg onload=alert(1)>.rb')
        expect(content).not_to include('lib/<b>foo</b>.rb')
      end

      it 'keeps the internal status filter attribute intact' do
        reporter.generate
        content = File.read(File.join(tmp_dir, 'mutation_report.html'))

        expect(content).to include('data-status="survived"')
      end
    end

    context 'with a comparison operator in the source line' do
      let(:results) do
        [
          {
            id: 1, status: :killed, killed: true, line: 3, type: :boolean,
            description: 'Change < to >',
            source_line: 'return a if a < b',
            mutated_line: 'return a if a > b'
          }
        ]
      end

      it 'shows the comparison literally as a &lt; b' do
        reporter.generate
        content = File.read(File.join(tmp_dir, 'mutation_report.html'))

        expect(content).to include('return a if a &lt; b')
        expect(content).not_to include('return a if a < b')
      end
    end

    context 'with a survived and a killed mutant (sorting + suggestions)' do
      let(:results) do
        [
          {
            id: 1, status: :killed, killed: true, line: 5, type: :arithmetic,
            description: 'killed one', source_line: 'a + b', mutated_line: 'a - b'
          },
          {
            id: 2, status: :survived, killed: false, line: 10, type: :boolean,
            description: 'survived one', source_line: 'x = true', mutated_line: 'x = false'
          }
        ]
      end

      it 'places survived mutants before killed ones regardless of line number' do
        reporter.generate
        content = File.read(File.join(tmp_dir, 'mutation_report.html'))

        survived_index = content.index('data-status="survived"')
        killed_index = content.index('data-status="killed"')

        expect(survived_index).not_to be_nil
        expect(killed_index).not_to be_nil
        expect(survived_index).to be < killed_index
      end

      it 'renders a suggestion block only for the survived mutant' do
        reporter.generate
        content = File.read(File.join(tmp_dir, 'mutation_report.html'))

        expect(content.scan('class="suggestion-box"').size).to eq(1)
        expect(content).to include('when survived one.')
        expect(content).not_to include('when killed one.')
      end
    end

    context 'with the full status taxonomy (ordering)' do
      let(:results) do
        [
          { id: 1, status: :error, killed: false, line: 1, type: :arithmetic, description: 'e' },
          { id: 2, status: :killed, killed: true, line: 2, type: :arithmetic, description: 'k' },
          { id: 3, status: :stillborn, killed: false, line: 3, type: :arithmetic, description: 'sb' },
          { id: 4, status: :timeout, killed: true, timeout: true, line: 4, type: :arithmetic, description: 't' },
          { id: 5, status: :survived, killed: false, line: 5, type: :boolean, description: 'survived here' }
        ]
      end

      it 'orders mutants by the status_of taxonomy, not the :killed boolean' do
        reporter.generate
        content = File.read(File.join(tmp_dir, 'mutation_report.html'))

        statuses_in_order = content.scan(/data-status="(\w+)"/).flatten

        expect(statuses_in_order).to eq(%w[survived killed timeout stillborn error])
      end
    end

    context 'with several survivors at the same file and line' do
      let(:results) do
        [
          {
            id: 1, status: :survived, killed: false, line: 12, type: :math,
            description: 'Change + to -', file_path: 'lib/foo.rb',
            source_line: 'a + b', mutated_line: 'a - b'
          },
          {
            id: 2, status: :survived, killed: false, line: 12, type: :math,
            description: 'Change + to *', file_path: 'lib/foo.rb',
            source_line: 'a + b', mutated_line: 'a * b'
          }
        ]
      end

      it 'renders one grouped card with the variant count and both variants' do
        reporter.generate
        content = File.read(File.join(tmp_dir, 'mutation_report.html'))

        expect(content.scan('data-status="survived"').size).to eq(1)
        expect(content).to include('lib/foo.rb:12 (2 variants)')
        expect(content).to include('Change + to -')
        expect(content).to include('Change + to *')
      end

      it 'renders a single removed line and one added line per variant' do
        reporter.generate
        content = File.read(File.join(tmp_dir, 'mutation_report.html'))

        expect(content.scan('a + b').size).to eq(1)
        expect(content).to include('a - b')
        expect(content).to include('a * b')
        expect(content.scan('class="diff-variant-ref"').size).to eq(2)
      end
    end

    context 'with a survivor whose source file exists on disk' do
      let(:source_path) { File.join(tmp_dir, 'calc.rb') }
      let(:reporter) { described_class.new(results, source_path, 'spec/foo_spec.rb', config) }
      let(:results) do
        [
          {
            id: 1, status: :survived, killed: false, line: 3, type: :comparison,
            description: 'Change < to >', file_path: source_path,
            source_line: 'return a if a < b', mutated_line: 'return a if a > b'
          }
        ]
      end

      before do
        File.write(source_path, <<~RUBY)
          class Calc
            def min(a, b)
              return a if a < b
              b
            end
          end
        RUBY
      end

      it 'renders a unified diff with hunk header and escaped context lines' do
        reporter.generate
        content = File.read(File.join(tmp_dir, 'mutation_report.html'))

        expect(content).to include('@@ -1,5 +1,5 @@')
        expect(content).to include('def min(a, b)')
        expect(content).to include('return a if a &lt; b')
        expect(content).to include('return a if a &gt; b')
        expect(content).not_to include('return a if a < b')
      end
    end

    context 'with a timeout mutant' do
      let(:results) do
        [
          {
            id: 1, status: :timeout, killed: true, timeout: true, line: 4, type: :arithmetic,
            description: 'Change + to -', file_path: 'lib/foo.rb',
            source_line: 'a + b', mutated_line: 'a - b'
          }
        ]
      end

      it 'renders the diff markers for the timeout detail view without a suggestion box' do
        reporter.generate
        content = File.read(File.join(tmp_dir, 'mutation_report.html'))

        expect(content).to include('data-status="timeout"')
        expect(content).to include('a - b')
        expect(content).not_to include('class="suggestion-box"')
      end
    end

    context 'with zero mutations' do
      let(:results) { [] }

      it 'handles division by zero gracefully' do
        expect { reporter.generate }.to output(/HTML report saved to/).to_stdout

        report_path = File.join(tmp_dir, 'mutation_report.html')
        content = File.read(report_path)

        expect(content).to include('>0</div>')
        expect(content).to include('>0.0% coverage</div>')
        expect(content).to include('>0.0%</div>')
      end
    end

    context 'when the run was cut short by fail-fast' do
      let(:reporter) { described_class.new(results, 'lib/foo.rb', 'spec/foo_spec.rb', config, interrupted: true) }

      it 'renders an interrupted-run banner in the report' do
        reporter.generate
        content = File.read(File.join(tmp_dir, 'mutation_report.html'))

        expect(content).to include('<div class="interrupted-banner">')
        expect(content).to include('Interrupted run')
        expect(content).to include('only the mutations processed before the interruption')
      end
    end

    it 'renders no interruption banner for a complete run' do
      reporter.generate
      content = File.read(File.join(tmp_dir, 'mutation_report.html'))

      expect(content).not_to include('<div class="interrupted-banner">')
    end
  end
end
