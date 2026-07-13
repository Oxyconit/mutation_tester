require_relative '../lib/mutation_tester'

puts Rainbow('=' * 80).bright
puts Rainbow('🧬 Minitest Example (Serial Execution)').cyan.bold
puts Rainbow('=' * 80).bright
puts ''

MutationTester.configure do |config|
  config.parallel_processes = 1
  config.reporters = %i[console html json]
  config.minimum_score = 90
  config.verbose = true
  config.fail_on_threshold = false
  config.output_dir = 'mutation_reports'
end

source_file = File.expand_path('calculator.rb', __dir__)
spec_file = File.expand_path('calculator_minitest.rb', __dir__)

unless File.exist?(source_file)
  puts Rainbow("❌ Source file not found: #{source_file}").red
  exit 1
end

unless File.exist?(spec_file)
  puts Rainbow("❌ Test file not found: #{spec_file}").red
  exit 1
end

success = MutationTester.run(source_file, spec_file)

puts ''
if success
  puts Rainbow('✅ Minitest example completed successfully!').green.bold
else
  puts Rainbow('⚠️  Minitest example completed with issues').yellow.bold
end
puts Rainbow('📊 Check mutation_reports/mutation_report.html for detailed results').cyan
