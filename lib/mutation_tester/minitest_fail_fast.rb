# frozen_string_literal: true

module MutationTester
  module MinitestFailFast
    PLUGIN_NAME = :mutation_tester_fail_fast

    class << self
      attr_accessor :enabled
    end

    self.enabled = true
  end
end

begin
  require 'minitest'
rescue LoadError
  Kernel.warn '[MutationTester] minitest is not loadable here; mutant runs will execute every test instead of stopping at the first failure.'
else
  module MutationTester
    module MinitestFailFast
      class Reporter < Minitest::AbstractReporter
        def record(result)
          return unless MinitestFailFast.enabled
          return if result.passed? || result.skipped?

          raise Interrupt
        end
      end
    end
  end

  module Minitest
    def self.plugin_mutation_tester_fail_fast_init(_options)
      reporter << MutationTester::MinitestFailFast::Reporter.new
    end
  end

  unless Minitest.extensions.include?(MutationTester::MinitestFailFast::PLUGIN_NAME)
    Minitest.register_plugin(MutationTester::MinitestFailFast::PLUGIN_NAME)
  end
end
