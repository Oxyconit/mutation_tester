# frozen_string_literal: true

require_relative '../test_recorder'

begin
  require 'minitest'
rescue LoadError
  Kernel.warn '[MutationTester] minitest is not loadable here; the kill matrix cannot record which tests fail.'
else
  module MutationTester
    module TestRecorder
      module MinitestHook
        PLUGIN_NAME = :mutation_tester_test_recorder

        class Reporter < Minitest::AbstractReporter
          def record(result)
            return unless TestRecorder.active?

            TestRecorder.write([entry_for(result)])
          end

          private

          def entry_for(result)
            owner = result.respond_to?(:klass) && result.klass ? result.klass : result.class.name
            {
              id: "#{owner}##{result.name}",
              name: result.name,
              line: line_of(result),
              status: status_of(result)
            }
          end

          def line_of(result)
            location = result.respond_to?(:source_location) ? result.source_location : nil
            location.is_a?(Array) ? location[1] : nil
          end

          def status_of(result)
            return 'skipped' if result.skipped?

            result.passed? ? 'passed' : 'failed'
          end
        end
      end
    end
  end

  module Minitest
    def self.plugin_mutation_tester_test_recorder_init(_options)
      reporter << MutationTester::TestRecorder::MinitestHook::Reporter.new
    end
  end

  unless Minitest.extensions.include?(MutationTester::TestRecorder::MinitestHook::PLUGIN_NAME)
    Minitest.register_plugin(MutationTester::TestRecorder::MinitestHook::PLUGIN_NAME)
  end
end
