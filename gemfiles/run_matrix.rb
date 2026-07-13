require 'bundler'
require_relative '../lib/mutation_tester'

framework = ARGV[0]
gemfile   = ARGV[1]

unless %w[minitest rspec].include?(framework) && gemfile
  warn 'usage: run_matrix.rb <minitest|rspec> <path/to/alternate.gemfile>'
  exit 2
end

repo_root    = File.expand_path('..', __dir__)
gemfile_path = File.expand_path(gemfile, repo_root)
fixture_dir  = File.join(repo_root, 'spec', 'fixtures', 'version_matrix')
source_file  = File.join(fixture_dir, 'adder.rb')
test_file    = File.join(fixture_dir, framework == 'minitest' ? 'adder_test.rb' : 'adder_spec.rb')

unless File.exist?(gemfile_path)
  warn "alternate gemfile not found: #{gemfile_path}"
  exit 2
end

version_probe =
  framework == 'minitest' ? 'require "minitest"; print Minitest::VERSION' : 'require "rspec/core"; print RSpec::Core::Version::STRING'

Bundler.with_unbundled_env do
  ENV['BUNDLE_GEMFILE'] = gemfile_path

  resolved = `bundle exec ruby -e '#{version_probe}'`.strip
  puts "== Matrix run: #{framework} #{resolved} (bundle: #{gemfile}) =="

  MutationTester.configure do |config|
    config.parallel_processes = 1
    config.reporters = %i[console]
    config.minimum_score = 100
    config.fail_on_threshold = true
    config.verbose = true
    config.output_dir = 'tmp/mutation_reports'
  end

  if MutationTester.run(source_file, test_file)
    puts "\nOK: #{framework} #{resolved} killed every mutant (100%)."
    exit 0
  else
    warn "\nFAIL: #{framework} #{resolved} mutation run did not reach 100%."
    exit 1
  end
end
