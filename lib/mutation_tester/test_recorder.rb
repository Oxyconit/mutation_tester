# frozen_string_literal: true

require 'json'
require 'tempfile'

module MutationTester
  module TestRecorder
    LOG_ENV = 'MUTATION_TESTER_TEST_LOG'
    SCOPE_ENV = 'MUTATION_TESTER_TEST_LOG_SCOPE'
    ROOT_ENV = 'MUTATION_TESTER_TEST_LOG_ROOT'
    FAILED = 'failed'
    RSPEC_HOOK_PATH = File.expand_path('test_recorder/rspec_hook.rb', __dir__).freeze
    MINITEST_HOOK_PATH = File.expand_path('test_recorder/minitest_hook.rb', __dir__).freeze

    class << self
      def capture(scope:, root:)
        log = Tempfile.new(['mutation_tester_tests', '.jsonl'])
        log.close
        outcome = yield(LOG_ENV => log.path, SCOPE_ENV => scope.to_s, ROOT_ENV => root.to_s)
        [outcome, read(log.path)]
      ensure
        log&.unlink
      end

      def read(path)
        return [] unless File.exist?(path)

        File.readlines(path).filter_map do |line|
          JSON.parse(line, symbolize_names: true)
        rescue JSON::ParserError
          nil
        end
      end

      def failed_ids(entries)
        Array(entries).select { |entry| entry[:status] == FAILED }.map { |entry| entry[:id] }.uniq.sort
      end

      def active?
        !ENV[LOG_ENV].to_s.empty?
      end

      def write(entries)
        return unless active?

        kept = ENV[SCOPE_ENV] == 'failures' ? entries.select { |entry| entry[:status] == FAILED } : entries
        return if kept.empty?

        File.open(ENV[LOG_ENV], 'a') do |file|
          kept.each { |entry| file.puts(JSON.generate(entry)) }
        end
      end

      def relative_to_root(path)
        root = ENV[ROOT_ENV].to_s
        return path if root.empty?

        prefixes = [root, resolved(root)].uniq.map { |candidate| "#{candidate.chomp('/')}/" }
        [path, resolved(path)].uniq.each do |candidate|
          prefix = prefixes.find { |value| candidate.start_with?(value) }
          return candidate.delete_prefix(prefix) if prefix
        end
        path
      end

      private

      def resolved(path)
        File.realpath(path)
      rescue SystemCallError
        path
      end
    end
  end
end
