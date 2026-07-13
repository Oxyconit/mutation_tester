require 'spec_helper'

RSpec.describe 'mutation_tester.gemspec package contents' do
  let(:gemspec_path) { File.expand_path('../mutation_tester.gemspec', __dir__) }
  let(:packaged_files) { Gem::Specification.load(gemspec_path).files }

  it 'excludes the test/ and spec/ suites' do
    leaked = packaged_files.grep(%r{\A(?:test|spec)/})

    expect(leaked).to be_empty, "test/spec files leaked into the gem: #{leaked.join(', ')}"
  end

  it 'excludes the gemfiles/ cross-version test harness' do
    leaked = packaged_files.grep(%r{\Agemfiles/})

    expect(leaked).to be_empty, "gemfiles/ files leaked into the gem: #{leaked.join(', ')}"
  end

  it 'includes the runtime library entry point and the CLI executable' do
    expect(packaged_files).to include('lib/mutation_tester.rb', 'exe/mutation_test')
  end

  it 'includes the rake tasks and readme that gem users rely on' do
    expect(packaged_files).to include('lib/tasks/mutation_tester.rake', 'readme.md')
  end

  it 'excludes the repo-internal benchmark rake task that depends on spec/ fixtures' do
    expect(packaged_files).not_to include('lib/tasks/bench.rake')
  end

  it 'includes the docs/ reference material the readme links to' do
    packaged_docs = packaged_files.grep(%r{\Adocs/})

    expect(packaged_docs).not_to be_empty, 'docs/ reference material is missing from the gem'
    expect(packaged_files).to include('docs/mutation-types.md', 'docs/json-schema.md')
  end

  it 'includes the CHANGELOG so it ships with the gem' do
    expect(packaged_files).to include('CHANGELOG.md')
  end
end
