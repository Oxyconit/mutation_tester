module MutationTester
  module Reporters
    class ConsoleReporter < BaseReporter
      def generate
        puts "\n" + Rainbow('=' * 80).bright
        puts Rainbow('🧬 MUTATION TESTING REPORT').bright.cyan
        puts Rainbow('=' * 80).bright

        print_summary
        print_survived_mutations if survived_count > 0

        puts "\n" + Rainbow('=' * 80).bright
      end

      private

      def print_summary
        puts "\n📊 Summary:"
        puts "  Total Mutations: #{total_count}"
        puts "  #{Rainbow("Killed: " + killed_count.to_s).green} ✅"
        puts "  #{Rainbow("Survived: " + survived_count.to_s).red} ❌"
        puts "  #{Rainbow("Timeout: " + timeout_count.to_s).yellow} ⏱️"
        puts "  #{Rainbow("Stillborn: " + stillborn_count.to_s).yellow} 🧬"
        puts "  #{Rainbow("Errors: " + error_count.to_s).yellow} 💥"
        print_excluded_summary
        print_selection_summary
        puts "  Mutation Score: #{Rainbow(mutation_score.to_s + "%").bright}"
        puts "  Quality: #{quality_rating}"
        puts "\n  " + progress_bar
      end

      def print_excluded_summary
        count = excluded_line_count
        return unless count.positive?

        puts "  #{Rainbow("Excluded: " + count.to_s + " line(s) (mutation_tester:disable)").blue} 🚫"
      end

      def print_selection_summary
        return unless selection_stats_available?

        puts "  #{Rainbow("Selection: #{subset_kill_count} kill(s) by test subset, #{full_kill_count} by full file").cyan} ⚡"
      end

      def selection_stats_available?
        return false unless @config.test_selection && FrameworkDetector.detect(@spec_file) == :rspec

        @config.runner != :in_memory || @results.any? { |result| result.key?(:kill_phase) }
      end

      def subset_kill_count
        kill_phase_count(:subset)
      end

      def full_kill_count
        kill_phase_count(:full)
      end

      def kill_phase_count(phase)
        @results.count { |r| r[:kill_phase] == phase }
      end

      def excluded_line_count
        MutationTester::Mutator.disabled_lines(File.read(@source_file)).size
      rescue StandardError
        0
      end

      def progress_bar
        filled = (mutation_score / 5).to_i
        empty = 20 - filled
        bar = Rainbow('█' * filled).green + Rainbow('░' * empty).white
        "[#{bar}] #{mutation_score}%"
      end

      def print_survived_mutations
        puts "\n" + Rainbow('⚠️  Survived Mutations (Need Improvement):').yellow
        puts Rainbow('-' * 80).yellow

        survivor_groups.each { |group| print_survivor_group(group) }
      end

      def print_survivor_group(group)
        mutations = group[:mutations]
        puts "\n  #{format_location(mutations.first)}#{variant_count_suffix(mutations)}"
        mutations.each do |mutation|
          puts "    #{Rainbow("##{mutation[:id]}").bright} [#{mutation[:type]}] #{mutation[:description]}"
        end
        puts
        diff_lines(mutations).each do |kind, text, mutation|
          puts render_diff_line(kind, text, mutation, mutations.size)
        end
        puts "  💡 Suggestion: #{suggestion_for(mutations)}"
      end

      def variant_count_suffix(mutations)
        mutations.size > 1 ? " (#{mutations.size} variants)" : ''
      end

      def suggestion_for(mutations)
        if mutations.size == 1
          "Add test to verify behavior when #{mutations.first[:description].downcase}"
        else
          "Add tests to verify behavior for each of the #{mutations.size} variants above"
        end
      end

      def render_diff_line(kind, text, mutation, variant_count)
        case kind
        when :hunk then "    #{Rainbow(text).cyan}"
        when :removed then "    #{Rainbow('-').red} #{text}"
        when :added then "    #{Rainbow('+').green} #{text}#{variant_marker(mutation, variant_count)}"
        else "      #{text}"
        end
      end

      def variant_marker(mutation, variant_count)
        variant_count > 1 ? "  #{Rainbow("(##{mutation[:id]})").bright}" : ''
      end

      def format_location(mutation)
        if @config.show_file_path
          "Location: #{Rainbow("#{mutation[:file_path]}:#{mutation[:line]}").cyan}"
        else
          "Line: #{Rainbow(mutation[:line].to_s).cyan}"
        end
      end
    end
  end
end
