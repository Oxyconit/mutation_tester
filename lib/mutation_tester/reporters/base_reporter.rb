module MutationTester
  module Reporters
    class BaseReporter
      attr_reader :results, :source_file, :spec_file, :config

      def self.score(results, policy: :killed)
        killing_statuses = policy == :separate ? %i[killed] : %i[killed timeout]
        scoring_statuses = killing_statuses + %i[survived]
        kills = results.count { |r| killing_statuses.include?(status_for(r)) }
        scored = results.count { |r| scoring_statuses.include?(status_for(r)) }
        return 0.0 if scored.zero?

        (kills.to_f / scored * 100).round(2)
      end

      def self.status_for(result)
        result[:status] || (result[:killed] ? :killed : :survived)
      end

      def initialize(results, source_file, spec_file, config, interrupted: false)
        @results = results
        @source_file = source_file
        @spec_file = spec_file
        @config = config
        @interrupted = interrupted
      end

      def interrupted?
        @interrupted
      end

      def generate
        raise NotImplementedError, 'Subclasses must implement #generate'
      end

      protected

      def status_of(result)
        self.class.status_for(result)
      end

      def count_with_status(status)
        @results.count { |r| status_of(r) == status }
      end

      def killed_count
        count_with_status(:killed)
      end

      def survived_count
        count_with_status(:survived)
      end

      def timeout_count
        count_with_status(:timeout)
      end

      def stillborn_count
        count_with_status(:stillborn)
      end

      def error_count
        count_with_status(:error)
      end

      def effective_killed_count
        return killed_count if @config.timeout_policy == :separate

        killed_count + timeout_count
      end

      def total_count
        @results.size
      end

      def mutation_score
        self.class.score(@results, policy: @config.timeout_policy)
      end

      def quality_rating
        score = mutation_score
        if score >= 90 then 'Excellent 🌟'
        elsif score >= 75 then 'Good 👍'
        elsif score >= 60 then 'Fair 😐'
        elsif score >= 40 then 'Poor 😟'
        else 'Critical ⚠️'
        end
      end

      def survived_mutations
        @results.select { |r| status_of(r) == :survived }
      end

      DIFF_CONTEXT_LINES = 2
      DIFF_DETAIL_STATUSES = %i[survived timeout].freeze

      def survivor_groups
        survived_mutations
          .group_by { |r| [r[:file_path], r[:line]] }
          .map { |(file_path, line), mutations| { file_path: file_path, line: line, mutations: mutations } }
          .sort_by { |group| group[:line].to_i }
      end

      def diff_lines(mutations)
        primary = mutations.first
        context = source_context_for(primary)
        return diff_without_context(mutations) unless context

        lines, first, last = context
        hunk = "@@ -#{first},#{last - first + 1} +#{first},#{last - first + mutations.size} @@"
        (first..last).each_with_object([[:hunk, hunk, nil]]) do |number, out|
          if number == primary[:line]
            out << [:removed, lines[number - 1], nil]
            indent = lines[number - 1][/\A\s*/]
            mutations.each { |m| out << [:added, indent + replacement_text(m), m] }
          else
            out << [:context, lines[number - 1], nil]
          end
        end
      end

      private

      def diff_without_context(mutations)
        primary = mutations.first
        removed = primary[:source_line] || primary[:original].to_s
        [[:removed, removed, nil]] + mutations.map { |m| [:added, replacement_text(m), m] }
      end

      def replacement_text(mutation)
        mutation[:mutated_line] || mutation[:mutated].to_s
      end

      def source_context_for(mutation)
        line = mutation[:line]
        return nil unless line.is_a?(Integer) && line >= 1 && mutation[:source_line]

        lines = cached_source_lines(mutation[:file_path] || @source_file)
        return nil unless lines && lines[line - 1] && lines[line - 1].strip == mutation[:source_line].strip

        first = [line - DIFF_CONTEXT_LINES, 1].max
        last = [line + DIFF_CONTEXT_LINES, lines.size].min
        [lines, first, last]
      end

      def cached_source_lines(path)
        @cached_source_lines ||= {}
        return @cached_source_lines[path] if @cached_source_lines.key?(path)

        @cached_source_lines[path] = begin
          File.read(path).lines.map(&:chomp)
        rescue StandardError
          nil
        end
      end
    end
  end
end
