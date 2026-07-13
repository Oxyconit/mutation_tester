task :environment unless Rake::Task.task_defined?(:environment)

namespace :mutation do
  desc 'Run mutation tests on a specific file'
  task :test, %i[source_file spec_file] => :environment do |_t, args|
    require 'mutation_tester'

    unless args[:source_file] && args[:spec_file]
      puts Rainbow('Usage: rake mutation:test[app/models/user.rb,spec/models/user_spec.rb]').yellow
      abort
    end

    source_file = args[:source_file]
    spec_file = args[:spec_file]

    unless File.exist?(source_file)
      puts Rainbow("❌ Source file not found: #{source_file}").red
      abort
    end

    unless File.exist?(spec_file)
      puts Rainbow("❌ Spec file not found: #{spec_file}").red
      abort
    end

    abort unless MutationTester.run(source_file, spec_file)
  end

  desc 'Run mutation tests on all models'
  task test_models: :environment do
    require 'mutation_tester'

    all_passed = true

    Dir.glob('app/models/**/*.rb').each do |source_file|
      spec_file = source_file.gsub('app/', 'spec/').gsub('.rb', '_spec.rb')

      next unless File.exist?(spec_file)

      puts "\n" + Rainbow('=' * 80).bright
      puts Rainbow("Testing: #{source_file}").cyan
      puts Rainbow('=' * 80).bright

      all_passed = false unless MutationTester.run(source_file, spec_file)
    end

    unless all_passed
      puts Rainbow("\n❌ One or more files did not meet the mutation score threshold").red
      abort
    end
  end
end

desc 'Run mutation tests (usage: rake "mutation_test[SOURCE_FILE,TEST_FILE]")'
task :mutation_test, [:source_file, :spec_file] do |_t, args|
  require 'mutation_tester'

  unless args[:source_file] && args[:spec_file]
    puts Rainbow('Usage: rake "mutation_test[SOURCE_FILE,TEST_FILE]"').yellow
    puts Rainbow('Example: rake "mutation_test[app/models/user.rb,spec/models/user_spec.rb]"').cyan
    abort
  end

  source_file = args[:source_file]
  spec_file = args[:spec_file]

  unless File.exist?(source_file)
    puts Rainbow("❌ Source file not found: #{source_file}").red
    puts Rainbow('💡 Tip: Make sure the path is correct and the file exists').yellow
    abort
  end

  unless File.exist?(spec_file)
    puts Rainbow("❌ Test file not found: #{spec_file}").red
    puts Rainbow('💡 Tip: Make sure the path is correct and the file exists').yellow
    abort
  end

  abort unless MutationTester.run(source_file, spec_file)
end
