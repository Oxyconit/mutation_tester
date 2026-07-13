require 'spec_helper'
require 'yaml'

RSpec.describe '.github/workflows/release.yml' do
  let(:workflow_path) { File.expand_path('../.github/workflows/release.yml', __dir__) }
  let(:raw) { File.read(workflow_path) }
  let(:workflow) { YAML.load_file(workflow_path) }

  def on_config
    workflow.fetch('on') { workflow.fetch(true) }
  end

  def permissions
    workflow['permissions'] || workflow.fetch('jobs').values.first['permissions']
  end

  it 'is valid YAML describing a jobs map' do
    expect { YAML.load_file(workflow_path) }.not_to raise_error
    expect(workflow).to be_a(Hash)
    expect(workflow.fetch('jobs')).to be_a(Hash)
  end

  it 'triggers only on a published GitHub Release' do
    expect(on_config.dig('release', 'types')).to eq(['published'])
  end

  it 'requests id-token: write for OIDC and keeps contents read-only' do
    expect(permissions['id-token']).to eq('write')
    expect(permissions['contents']).to eq('read')
  end

  it 'publishes via trusted publishing without any API-key secret' do
    expect(raw).not_to match(/RUBYGEMS_API_KEY/i)
    expect(raw).not_to include('secrets.')
    expect(raw).to include('rubygems/configure-rubygems-credentials')
    expect(raw).to include('gem push')
  end

  it 'verifies the gem version against the release tag before publishing' do
    expect(raw).to include('MutationTester::VERSION')
    expect(raw).to include('github.event.release.tag_name')
  end
end
