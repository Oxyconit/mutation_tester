# frozen_string_literal: true

require_relative '../test_recorder'

module MutationTester
  module TestRecorder
    module RSpecHook
      STATUSES = { passed: 'passed', failed: 'failed', pending: 'skipped' }.freeze

      class << self
        def install
          return if @installed

          @installed = true
          ::RSpec.configure do |config|
            config.after(:suite) { MutationTester::TestRecorder::RSpecHook.flush }
          end
        end

        def flush
          return unless TestRecorder.active?

          TestRecorder.write(::RSpec.world.all_examples.filter_map { |example| entry_for(example) })
        end

        private

        def entry_for(example)
          status = STATUSES[example.execution_result.status]
          return nil unless status

          metadata = example.metadata
          {
            id: "#{spec_path(metadata)}[#{metadata[:scoped_id]}]",
            name: example.full_description,
            line: metadata[:file_path] == metadata[:rerun_file_path] ? metadata[:line_number] : nil,
            status: status
          }
        end

        def spec_path(metadata)
          TestRecorder.relative_to_root(File.expand_path(metadata[:rerun_file_path]))
        end
      end
    end
  end
end

MutationTester::TestRecorder::RSpecHook.install
