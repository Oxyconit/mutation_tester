require 'spec_helper'
require 'yaml'

RSpec.describe 'AI mutation gate examples' do
  describe 'examples/github_actions/ai_mutation_gate.yml' do
    let(:template_path) do
      File.expand_path('../examples/github_actions/ai_mutation_gate.yml', __dir__)
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

    it 'runs mutation_test in machine mode (--json) and captures the report' do
      expect(raw).to match(/bundle exec mutation_test --json/)
      expect(raw).to include('mutation_report.json')
    end

    it 'extracts the surviving mutants as the worklist of test gaps' do
      expect(raw).to include('select(.status == "survived")')
      expect(raw).to include('survivors.json')
      expect(raw).to include('.file_path')
      expect(raw).to include('.line')
      expect(raw).to include('.original')
      expect(raw).to include('.mutated')
    end

    it 'writes the survivors into the GitHub job summary' do
      expect(raw).to include('GITHUB_STEP_SUMMARY')
    end

    it 'uploads the report and worklist as an artifact, even on failure' do
      expect(raw).to include('actions/upload-artifact@v4')
      expect(raw).to match(/if:\s*always\(\)/)
    end

    it 'still enforces the threshold gate after collecting the worklist' do
      expect(raw).to include("steps.mutation.outcome == 'failure'")
    end
  end

  describe 'examples/hooks/pre-push' do
    let(:hook_path) { File.expand_path('../examples/hooks/pre-push', __dir__) }
    let(:raw) { File.read(hook_path) }

    it 'is a POSIX sh script' do
      expect(raw).to start_with('#!/bin/sh')
    end

    it 'runs mutation_test in machine mode against a source/test pair' do
      expect(raw).to match(/bundle exec mutation_test --json/)
    end

    it 'reads the score from the JSON and gates on a threshold' do
      expect(raw).to include('THRESHOLD')
      expect(raw).to include('.summary.mutation_score')
    end

    it 'lists the surviving mutants when it blocks the push' do
      expect(raw).to include('select(.status == "survived")')
      expect(raw).to match(/exit "\$status"/)
    end
  end
end
