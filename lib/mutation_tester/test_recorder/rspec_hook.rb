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

          TestRecorder.write(all_examples.filter_map { |example| entry_for(example) })
        rescue StandardError => e
          Kernel.warn "[MutationTester] The kill matrix could not record the rspec results: #{e.class}: #{e.message}"
        end

        private

        def all_examples
          ::RSpec.world.example_groups.flat_map(&:descendants).flat_map(&:examples)
        end

        def entry_for(example)
          status = STATUSES[example.execution_result.status]
          return nil unless status

          metadata = example.metadata
          {
            id: id_for(metadata),
            name: example.full_description,
            line: metadata[:file_path] == rerun_path(metadata) ? metadata[:line_number] : nil,
            status: status
          }
        end

        def id_for(metadata)
          path = TestRecorder.relative_to_root(File.expand_path(rerun_path(metadata)))
          return "#{path}[#{metadata[:scoped_id]}]" if metadata[:scoped_id]

          "#{path}:#{metadata[:line_number]}"
        end

        def rerun_path(metadata)
          metadata[:rerun_file_path] || metadata[:file_path]
        end
      end
    end
  end
end

MutationTester::TestRecorder::RSpecHook.install
