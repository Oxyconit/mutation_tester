require 'spec_helper'
require 'yaml'

RSpec.describe 'examples/github_actions/redundant_tests.yml' do
  let(:template_path) do
    File.expand_path('../examples/github_actions/redundant_tests.yml', __dir__)
  end
  let(:raw) { File.read(template_path) }
  let(:doc) { YAML.safe_load(raw) }
  let(:job) { doc.fetch('jobs').values.first }
  let(:run_scripts) { job['steps'].map { |step| step['run'] }.compact.join("\n") }

  it 'is well-formed YAML with an ordered list of steps on ubuntu' do
    expect(job['runs-on']).to eq('ubuntu-latest')
    expect(job['steps']).to be_an(Array)
    expect(job['steps']).not_to be_empty
  end

  it 'runs as a scheduled or manual audit instead of on every push' do
    triggers = doc.fetch(true) { doc.fetch('on') }

    expect(triggers.keys).to contain_exactly('schedule', 'workflow_dispatch')
  end

  it 'checks out the repository and sets up Ruby with bundler-cache' do
    expect(raw).to include('actions/checkout@v5')
    expect(raw).to include('ruby/setup-ruby@v1')
    expect(raw).to match(/bundler-cache:\s*true/)
  end

  it 'runs the kill matrix in machine mode without letting the score fail the audit' do
    expect(run_scripts).to match(/bundle exec mutation_test --kill-matrix --json --minimum-score 0/)
    expect(run_scripts).not_to include('--fail-fast')
    expect(run_scripts).to include('kill_matrix.json')
  end

  it 'derives the candidates from the baseline test list and the killers of each mutant' do
    expect(run_scripts).to include('.tests[]')
    expect(run_scripts).to include('.mutations[].killed_by[]')
    expect(run_scripts).to include('select(.status == "passed"')
    expect(run_scripts).to include('all($mine[]; length > 1)')
  end

  it 'reads both the single-file report and the multi-file envelope' do
    expect(run_scripts.scan('(.files // [.])[]').size).to eq(3)
  end

  it 'reports the mutants whose killers are unknown so the lists are not over-trusted' do
    expect(run_scripts).to include('(.status == "killed" or .status == "timeout") and (.killed_by | length) == 0')
  end

  it 'publishes the candidates to the job summary and uploads the report' do
    expect(run_scripts).to include('GITHUB_STEP_SUMMARY')
    expect(raw).to include('actions/upload-artifact@v4')
    expect(raw).to match(/if:\s*always\(\)/)
  end
end
