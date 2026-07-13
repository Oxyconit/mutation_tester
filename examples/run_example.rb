require_relative '../lib/mutation_tester'

MutationTester.configure do |config|
  config.reporters = %i[console html json]
  config.minimum_score = 90
  config.verbose = true
  config.fail_on_threshold = true
end

source_file = File.expand_path('calculator.rb', __dir__)
spec_file = File.expand_path('calculator_spec.rb', __dir__)

unless File.exist?(source_file)
  puts Rainbow("❌ Source file not found: #{source_file}").red
  exit 1
end

unless File.exist?(spec_file)
  puts Rainbow("❌ Spec file not found: #{spec_file}").red
  exit 1
end

success = MutationTester.run(source_file, spec_file)

if success
  puts "\n" + Rainbow('✅ Example completed!').green
  puts Rainbow('Check mutation_reports/mutation_report.html for detailed results').cyan
else
  puts "\n" + Rainbow('❌ Example failed!').red
  exit 1
end
