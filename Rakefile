require 'bundler/gem_tasks'
require 'rspec/core/rake_task'
require_relative 'lib/mutation_tester/rake_task'

RSpec::Core::RakeTask.new(:spec)

task default: :spec

desc 'Run the full test suite (unit + integration RSpec + Minitest)'
task :test do
  puts '--- Running RSpec Suite (unit + integration) ---'
  sh 'bundle exec rspec'

  puts "\n--- Running Minitest Suite ---"
  sh 'ruby test/mutator_test.rb'
end

namespace :test do
  task :unit do
    sh 'bundle exec rspec --exclude-pattern "**/integration_spec.rb"'
  end

  task :integration do
    sh 'bundle exec rspec spec/integration_spec.rb'
  end

  task :minitest do
    sh 'ruby test/mutator_test.rb'
  end
end

desc 'Run example mutation test (default: RSpec)'
task :example do
  require_relative 'examples/run_example'
end

namespace :example do
  desc 'Run RSpec example (serial execution)'
  task :rspec do
    require_relative 'examples/run_example_rspec'
  end

  desc 'Run Minitest example (serial execution)'
  task :minitest do
    require_relative 'examples/run_example_minitest'
  end

  desc 'Run RSpec example (parallel execution)'
  task :rspec_parallel do
    require_relative 'examples/run_example_parallel_rspec'
  end

  desc 'Run Minitest example (parallel execution)'
  task :minitest_parallel do
    require_relative 'examples/run_example_parallel_minitest'
  end
end
