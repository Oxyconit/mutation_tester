require 'spec_helper'
require 'tmpdir'
require 'json'

RSpec.describe MutationTester::Reporters::JsonReporter do
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
    it 'creates a JSON report file' do
      expect { reporter.generate }.to output(/JSON report saved to/).to_stdout

      report_path = File.join(tmp_dir, 'mutation_report.json')
      expect(File.exist?(report_path)).to be true

      json = JSON.parse(File.read(report_path), symbolize_names: true)

      expect(json[:schema_version]).to eq(MutationTester::Reporters::JsonReporter::SCHEMA_VERSION)
      expect(json[:schema_version]).to eq(1)
      expect(json[:metadata][:source_file]).to eq('lib/foo.rb')
      expect(json[:summary][:total]).to eq(2)
      expect(json[:summary][:killed]).to eq(1)
      expect(json[:summary][:mutation_score]).to eq(50.0)
      expect(json[:mutations].size).to eq(2)
      expect(json[:mutations][0][:type]).to eq('arithmetic')
    end

    context 'with the full status taxonomy' do
      let(:results) do
        [
          { id: 1, status: :killed, killed: true, line: 1, type: :arithmetic, description: 'k' },
          { id: 2, status: :survived, killed: false, line: 2, type: :boolean, description: 's' },
          { id: 3, status: :timeout, killed: true, timeout: true, line: 3, type: :arithmetic, description: 't' },
          { id: 4, status: :stillborn, killed: false, line: 4, type: :arithmetic, description: 'sb' },
          { id: 5, status: :error, killed: false, line: 5, type: :arithmetic, description: 'Error: boom' }
        ]
      end

      it 'keeps killed/survived and adds categories plus per-mutant status' do
        reporter.generate
        json = JSON.parse(File.read(File.join(tmp_dir, 'mutation_report.json')), symbolize_names: true)

        expect(json[:summary][:killed]).to eq(2)
        expect(json[:summary][:survived]).to eq(1)

        expect(json[:summary][:categories]).to eq(
          killed: 1, survived: 1, timeout: 1, stillborn: 1, error: 1
        )

        expect(json[:summary][:mutation_score]).to eq(66.67)

        expect(json[:mutations].map { |m| m[:status] })
          .to eq(%w[killed survived timeout stillborn error])
        expect(json[:mutations][4][:description]).to include('boom')
      end
    end
  end

  describe 'additive diff field' do
    let(:results) do
      [
        {
          id: 1, status: :killed, killed: true, line: 1, type: :arithmetic,
          description: 'k', source_line: 'a + b', mutated_line: 'a - b'
        },
        {
          id: 2, status: :survived, killed: false, line: 2, type: :boolean,
          description: 's', source_line: 'flag = true', mutated_line: 'flag = false'
        },
        {
          id: 3, status: :timeout, killed: true, timeout: true, line: 3, type: :arithmetic,
          description: 't', source_line: 'a * b', mutated_line: 'a / b'
        }
      ]
    end

    it 'adds a diff only for survived and timeout mutants and keeps schema_version at 1' do
      json = JSON.parse(reporter.render, symbolize_names: true)

      expect(json[:schema_version]).to eq(1)

      by_status = json[:mutations].group_by { |m| m[:status] }
      expect(by_status['killed'].first).not_to have_key(:diff)
      expect(by_status['survived'].first[:diff]).to eq("- flag = true\n+ flag = false")
      expect(by_status['timeout'].first[:diff]).to eq("- a * b\n+ a / b")
    end

    it 'keeps every pre-existing mutation field unchanged next to the diff' do
      json = JSON.parse(reporter.render, symbolize_names: true)
      survived = json[:mutations].find { |m| m[:status] == 'survived' }

      expect(survived).to include(
        id: 2, line: 2, type: 'boolean', description: 's',
        source_line: 'flag = true', mutated_line: 'flag = false'
      )
    end
  end

  describe 'internal kill phase field' do
    let(:results) do
      [
        {
          id: 1, status: :killed, killed: true, kill_phase: :subset,
          line: 1, type: :arithmetic, description: 'k'
        },
        {
          id: 2, status: :timeout, killed: true, timeout: true, kill_phase: :full,
          line: 3, type: :arithmetic, description: 't', source_line: 'a * b', mutated_line: 'a / b'
        }
      ]
    end

    it 'never emits kill_phase and keeps the killed entry keys unchanged' do
      json = JSON.parse(reporter.render, symbolize_names: true)

      expect(json[:mutations]).to all(satisfy { |m| !m.key?(:kill_phase) })
      expect(json[:mutations][0].keys)
        .to contain_exactly(:id, :status, :killed, :line, :type, :description)
    end
  end

  describe '#render' do
    it 'returns a JSON string byte-identical to the written report file' do
      reporter.generate
      file_contents = File.read(File.join(tmp_dir, 'mutation_report.json'))
      expect(reporter.render).to eq(file_contents)
    end

    it 'produces parseable JSON pinned to the documented schema' do
      json = JSON.parse(reporter.render, symbolize_names: true)

      expect(json[:schema_version]).to eq(1)
      expect(json.keys).to include(:schema_version, :interrupted, :metadata, :summary, :mutations)
      expect(json[:summary].keys).to include(:total, :killed, :survived, :mutation_score, :categories)
      expect(json[:summary][:categories].keys)
        .to contain_exactly(:killed, :survived, :timeout, :stillborn, :error)
    end

    it 'keeps the single-file report free of the multi-file envelope keys' do
      json = JSON.parse(reporter.render, symbolize_names: true)

      expect(json.keys).to contain_exactly(:schema_version, :interrupted, :metadata, :summary, :mutations)
      expect(json.keys).not_to include(:survivors, :files)
    end
  end

  describe 'interrupted flag' do
    it 'reports interrupted false for a complete run while keeping schema_version at 1' do
      json = JSON.parse(reporter.render, symbolize_names: true)

      expect(json[:schema_version]).to eq(1)
      expect(json[:interrupted]).to be false
    end

    it 'reports interrupted true for a run cut short by fail-fast' do
      partial_reporter = described_class.new(results, 'lib/foo.rb', 'spec/foo_spec.rb', config, interrupted: true)
      json = JSON.parse(partial_reporter.render, symbolize_names: true)

      expect(json[:interrupted]).to be true
    end
  end
end

RSpec.describe MutationTester::Reporters::BatchJsonReporter do
  let(:config) { MutationTester::Configuration.new }

  let(:killed_result) do
    {
      id: 1, status: :killed, killed: true, kill_phase: :subset, line: 3, type: :boolean,
      file_path: File.expand_path('lib/calc.rb'), original: 'true', mutated: 'false',
      source_line: 'flag = true', mutated_line: 'flag = false', description: 'Change true to false'
    }
  end

  let(:survivor_result) do
    {
      id: 2, status: :survived, killed: false, line: 4, type: :arithmetic,
      file_path: File.expand_path('lib/calc.rb'), original: '+', mutated: '-',
      source_line: 'a + b', mutated_line: 'a - b', description: 'Change + to -'
    }
  end

  let(:timeout_result) do
    {
      id: 3, status: :timeout, killed: true, timeout: true, line: 5, type: :arithmetic,
      file_path: File.expand_path('lib/calc.rb'), original: '*', mutated: '/',
      source_line: 'a * b', mutated_line: 'a / b', description: 'Change * to /'
    }
  end

  def processed_entry(results)
    MutationTester::BatchRunner::ProcessedEntry.new(
      source_file: 'lib/calc.rb', spec_file: 'spec/calc_spec.rb',
      score: MutationTester::Reporters::BaseReporter.score(results),
      passed: false, output_dir: 'tmp/calc', results: results, interrupted: false
    )
  end

  let(:batch_result) do
    MutationTester::BatchRunner::Result.new(
      processed: [processed_entry([killed_result, survivor_result, timeout_result])],
      skipped: [
        MutationTester::BatchRunner::SkippedEntry.new(
          source_file: 'lib/orphan.rb', expected_spec: 'spec/orphan_spec.rb', reason: :no_spec
        )
      ],
      unchanged: [],
      interrupted: false
    )
  end

  let(:reporter) { described_class.new(batch_result, config, passed: false) }
  let(:json) { JSON.parse(reporter.render, symbolize_names: true) }

  it 'pins the envelope to exactly the documented keys' do
    expect(json.keys).to contain_exactly(:schema_version, :summary, :survivors, :files)
    expect(json[:schema_version]).to eq(MutationTester::Reporters::BatchJsonReporter::SCHEMA_VERSION)
    expect(json[:schema_version]).to eq(1)
    expect(json[:summary].keys).to contain_exactly(:files, :processed, :skipped, :score, :passed, :interrupted)
    expect(json[:summary][:skipped].first.keys).to contain_exactly(:file, :reason)
    expect(json[:survivors].first.keys).to contain_exactly(:file, :line, :type, :original, :mutated)
  end

  it 'summarizes counts, skip reasons, the aggregate score and the run outcome' do
    expect(json[:summary]).to include(files: 2, processed: 1, score: 66.67, passed: false, interrupted: false)
    expect(json[:summary][:skipped]).to eq([{ file: 'lib/orphan.rb', reason: 'no matching spec file' }])
  end

  it 'lists only surviving mutants, composed without bookkeeping fields' do
    expect(json[:survivors]).to eq(
      [{ file: File.expand_path('lib/calc.rb'), line: 4, type: 'arithmetic', original: '+', mutated: '-' }]
    )
  end

  it 'represents a survivor file with the same path as its files entry so agents can join them' do
    survivor_file = json[:survivors].first[:file]
    matching = json[:files].find { |report| report[:metadata][:source_file] == survivor_file }

    expect(survivor_file).to eq(File.expand_path('lib/calc.rb'))
    expect(matching).not_to be_nil
  end

  it 'reuses the existing per-file schema for every files entry' do
    file_report = json[:files].first

    expect(file_report.keys).to contain_exactly(:schema_version, :interrupted, :metadata, :summary, :mutations)
    expect(file_report[:schema_version]).to eq(1)
    expect(file_report[:interrupted]).to be false
    expect(file_report[:metadata][:source_file]).to eq(File.expand_path('lib/calc.rb'))
    expect(file_report[:metadata][:spec_file]).to eq(File.expand_path('spec/calc_spec.rb'))
    expect(file_report[:summary][:categories].keys).to contain_exactly(:killed, :survived, :timeout, :stillborn, :error)
    expect(file_report[:mutations].size).to eq(3)
    expect(file_report[:mutations]).to all(satisfy { |m| !m.key?(:kill_phase) })
  end

  it 'reports the passed flag it was handed for the whole run' do
    passing = described_class.new(batch_result, config, passed: true)
    expect(JSON.parse(passing.render, symbolize_names: true)[:summary][:passed]).to be true
  end

  it 'renders an empty run as an envelope with zero files and no survivors' do
    empty = MutationTester::BatchRunner::Result.new(processed: [], skipped: [], unchanged: [], interrupted: false)
    empty_json = JSON.parse(described_class.new(empty, config, passed: false).render, symbolize_names: true)

    expect(empty_json[:summary]).to include(files: 0, processed: 0, score: 0.0, passed: false)
    expect(empty_json[:survivors]).to eq([])
    expect(empty_json[:files]).to eq([])
  end
end

require 'open3'
require 'rbconfig'

RSpec.describe 'MutationTester::Reporters::JsonReporter timestamp portability across Ruby versions' do
  TIME_GUARD_ROOT = File.expand_path('../../..', __dir__)
  TIME_GUARD_GEMFILE = File.join(TIME_GUARD_ROOT, 'Gemfile')
  TIME_GUARD_ISO8601 = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})\z/

  TIME_GUARD_SCRIPT = <<~'RUBY'
    require 'bundler/setup'
    require 'json'
    time_before = $LOADED_FEATURES.any? { |feature| feature.end_with?('/time.rb') }
    require 'mutation_tester'
    time_after = $LOADED_FEATURES.any? { |feature| feature.end_with?('/time.rb') }
    reporter = MutationTester::Reporters::JsonReporter.new(
      [], 'lib/foo.rb', 'spec/foo_spec.rb', MutationTester::Configuration.new
    )
    generated_at = JSON.parse(reporter.render).dig('metadata', 'generated_at')
    $stdout.puts("TIME_BEFORE=#{time_before}")
    $stdout.puts("TIME_AFTER=#{time_after}")
    $stdout.puts("GENERATED_AT=#{generated_at}")
  RUBY

  def run_isolated_report
    stdout = stderr = status = nil
    Bundler.with_unbundled_env do
      stdout, stderr, status = Open3.capture3(
        { 'BUNDLE_GEMFILE' => TIME_GUARD_GEMFILE },
        RbConfig.ruby, '-e', TIME_GUARD_SCRIPT,
        chdir: TIME_GUARD_ROOT
      )
    end
    fields = stdout.each_line.each_with_object({}) do |line, acc|
      key, sep, value = line.strip.partition('=')
      acc[key] = value unless sep.empty?
    end
    [fields, stderr, status]
  end

  it 'pulls in the time stdlib and emits a valid ISO8601 generated_at from a fresh process' do
    fields, stderr, status = run_isolated_report

    expect(status.exitstatus).to eq(0), "isolated report process failed:\n#{stderr}"
    expect(stderr).not_to include('NoMethodError')
    expect(fields['TIME_BEFORE']).to eq('false'), 'time stdlib was already loaded before requiring the gem, so this guard could not attribute the load to the gem'
    expect(fields['TIME_AFTER']).to eq('true'), 'requiring the gem did not load the time stdlib that provides Time#iso8601 on Ruby 3.x'
    expect(fields['GENERATED_AT']).to match(TIME_GUARD_ISO8601)
  end
end
