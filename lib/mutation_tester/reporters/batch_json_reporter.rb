module MutationTester
  module Reporters
    class BatchJsonReporter
      SCHEMA_VERSION = 1

      def initialize(result, config, passed:)
        @result = result
        @config = config
        @passed = passed
      end

      def render
        JSON.pretty_generate(envelope)
      end

      private

      def envelope
        {
          schema_version: SCHEMA_VERSION,
          summary: {
            files: @result.processed.size + @result.skipped.size,
            processed: @result.processed.size,
            skipped: skipped_entries,
            score: aggregate_score,
            passed: @passed,
            interrupted: @result.interrupted?
          },
          survivors: survivor_entries,
          files: file_reports
        }
      end

      def skipped_entries
        @result.skipped.map do |entry|
          {
            file: entry.source_file,
            reason: BatchRunner::SKIP_REASONS.fetch(entry.reason || :no_spec)
          }
        end
      end

      def survivor_entries
        @result.survivors.map do |survivor|
          {
            file: File.expand_path(survivor[:file]),
            line: survivor[:line],
            type: survivor[:type],
            original: survivor[:original],
            mutated: survivor[:mutated]
          }
        end
      end

      def aggregate_score
        BaseReporter.score(@result.processed.flat_map { |entry| entry.results || [] }, policy: @config.timeout_policy)
      end

      def file_reports
        @result.processed.map do |entry|
          JsonReporter.new(
            entry.results || [],
            File.expand_path(entry.source_file),
            File.expand_path(entry.spec_file),
            @config,
            interrupted: !!entry.interrupted
          ).report_data
        end
      end
    end
  end
end
