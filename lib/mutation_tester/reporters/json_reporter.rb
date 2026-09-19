require 'time'

module MutationTester
  module Reporters
    class JsonReporter < BaseReporter
      SCHEMA_VERSION = 1

      def generate
        output_file = File.join(@config.output_dir, 'mutation_report.json')

        File.write(output_file, render)
        puts Rainbow("✓ JSON report saved to: #{output_file}").green
        output_file
      end

      def render
        @render ||= JSON.pretty_generate(report_data)
      end

      def report_data
        {
          schema_version: SCHEMA_VERSION,
          interrupted: interrupted?,
          **kill_matrix_fields,
          metadata: {
            version: MutationTester::VERSION,
            generated_at: Time.now.iso8601,
            source_file: @source_file,
            spec_file: @spec_file
          },
          summary: {
            total: total_count,
            killed: effective_killed_count,
            survived: survived_count,
            mutation_score: mutation_score,
            quality_rating: quality_rating,
            categories: {
              killed: killed_count,
              survived: survived_count,
              timeout: timeout_count,
              stillborn: stillborn_count,
              error: error_count
            }
          },
          mutations: @results.map { |r| mutation_entry(r) }
        }
      end

      private

      def kill_matrix_fields
        return {} unless @config.kill_matrix

        { kill_matrix: true, tests: @tests.map { |test| test.slice(:id, :name, :line, :status) } }
      end

      def mutation_entry(result)
        status = status_of(result)
        entry = result.merge(status: status)
        entry.delete(:kill_phase)
        entry[:diff] = diff_text(result) if DIFF_DETAIL_STATUSES.include?(status)
        entry
      end

      def diff_text(result)
        diff_lines([result]).map { |kind, text, _| "#{diff_prefix(kind)}#{text}" }.join("\n")
      end

      def diff_prefix(kind)
        { removed: '- ', added: '+ ', context: '  ' }.fetch(kind, '')
      end
    end
  end
end
