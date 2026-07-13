require 'spec_helper'
require 'yaml'

RSpec.describe 'examples/github_actions/mutation_test.yml' do
  let(:template_path) do
    File.expand_path('../examples/github_actions/mutation_test.yml', __dir__)
  end
  let(:raw) { File.read(template_path) }
  let(:doc) { YAML.safe_load(raw) }

  it 'is well-formed YAML' do
    expect { YAML.safe_load(raw) }.not_to raise_error
  end

  it 'defines a job with an ordered list of steps' do
    job = doc.fetch('jobs').values.first

    expect(job['runs-on']).to eq('ubuntu-latest')
    expect(job['steps']).to be_an(Array)
    expect(job['steps']).not_to be_empty
  end

  it 'checks out the repository and sets up Ruby with bundler-cache' do
    expect(raw).to include('actions/checkout@v4')
    expect(raw).to include('ruby/setup-ruby@v1')
    expect(raw).to match(/bundler-cache:\s*true/)
  end

  it 'runs mutation_test as the quality gate (exit code fails the job)' do
    expect(raw).to match(/bundle exec mutation_test\s+\S+\s+\S+/)
  end

  it 'uploads the report directory as an artifact, even on failure' do
    expect(raw).to include('actions/upload-artifact@v4')
    expect(raw).to match(/if:\s*always\(\)/)
    expect(raw).to include('tmp/mutation_reports/')
  end

  it 'documents the parallel variant via MUTATION_TESTER_PARALLEL_PROCESSES' do
    expect(raw).to include('MUTATION_TESTER_PARALLEL_PROCESSES')
  end

  it 'documents running several source/test pairs in one job' do
    expect(raw).to include('--output-dir')
    expect(raw.scan(/bundle exec mutation_test/).length).to be >= 2
  end

  it 'documents the incremental pull request variant with --since and --fail-fast' do
    expect(raw).to include('--since "origin/${{ github.base_ref }}"')
    expect(raw).to include('--fail-fast')
    expect(raw).to match(/fetch-depth:\s*0/)
  end
end
