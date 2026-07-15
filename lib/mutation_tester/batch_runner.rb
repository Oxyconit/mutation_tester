require 'digest'
require 'open3'
require 'pathname'
require 'set'

module MutationTester
  class BatchRunner
    NAME_PLACEHOLDER = '{name}'.freeze

    DEFAULT_SPEC_TEMPLATE = 'spec/{name}_spec.rb'.freeze

    TEST_FILE_SUFFIXES = ['_spec.rb', '.spec.rb', '_test.rb'].freeze

    SKIP_REASONS = {
      missing: 'file not found',
      not_ruby: 'not a Ruby source file',
      test_file: 'a test file, not a mutable source',
      no_spec: 'no matching spec file'
    }.freeze

    SKIP_ORDER = %i[missing not_ruby test_file no_spec].freeze

    ProcessedEntry = Struct.new(:source_file, :spec_file, :score, :passed, :output_dir, :results, :interrupted, :degraded, keyword_init: true) do
      def passed?
        passed
      end

      def degraded?
        !!degraded
      end
    end

    SkippedEntry = Struct.new(:source_file, :expected_spec, :reason, keyword_init: true)

    Result = Struct.new(:processed, :skipped, :unchanged, :interrupted, keyword_init: true) do
      def success?
        processed.all?(&:passed?)
      end

      def survivors
        processed.flat_map do |entry|
          (entry.results || [])
            .select { |r| Reporters::BaseReporter.status_for(r) == :survived }
            .map do |r|
              {
                file: entry.source_file,
                line: r[:line],
                type: r[:type],
                original: r[:original],
                mutated: r[:mutated]
              }
            end
        end
      end

      def matched_any?
        !(processed.empty? && skipped.empty? && (unchanged || []).empty?)
      end

      def interrupted?
        !!interrupted
      end
    end

    def self.changed_files_since(revision, dir: Dir.pwd)
      toplevel = git_capture(dir, 'rev-parse', '--show-toplevel') do |stderr|
        "not a git repository (--since needs one): #{stderr}"
      end.strip

      git_capture(dir, 'rev-parse', '--verify', '--quiet', "#{revision}^{commit}") do |stderr|
        detail = stderr.empty? ? 'not a commit' : stderr
        "unknown revision #{revision.inspect}: #{detail}"
      end

      diff = git_capture(dir, 'diff', '--name-only', revision) do |stderr|
        "git diff --name-only #{revision} failed: #{stderr}"
      end
      untracked = git_capture(dir, 'ls-files', '--others', '--exclude-standard') do |stderr|
        "git ls-files failed: #{stderr}"
      end

      (diff.lines + untracked.lines)
        .map(&:strip).reject(&:empty?)
        .map { |path| File.expand_path(path, toplevel) }
        .to_set
    end

    def self.staged_files(dir: Dir.pwd)
      toplevel = git_capture(dir, 'rev-parse', '--show-toplevel') do |stderr|
        "not a git repository (--staged needs one): #{stderr}"
      end.strip

      staged = git_capture(dir, 'diff', '--cached', '--name-only', '--diff-filter=d') do |stderr|
        "git diff --cached --name-only failed: #{stderr}"
      end

      base = Pathname.new(File.realpath(dir))
      staged.lines
            .map(&:strip).reject(&:empty?)
            .map { |path| Pathname.new(File.expand_path(path, toplevel)).relative_path_from(base).to_s }
    end

    def self.test_file?(path)
      basename = File.basename(path)
      return true if TEST_FILE_SUFFIXES.any? { |suffix| basename.end_with?(suffix) }
      return true if basename.start_with?('test_') && basename.end_with?('.rb')

      FrameworkDetector.minitest_content?(path)
    end

    def self.git_capture(dir, *args)
      stdout, stderr, status = Open3.capture3('git', '-C', dir, *args)
      raise MutationTester::Error, yield(stderr.strip) unless status.success?

      stdout
    rescue Errno::ENOENT
      raise MutationTester::Error, 'git executable not found; --since and --staged need git and a git repository'
    end
    private_class_method :git_capture

    def initialize(glob: nil, files: nil, spec_template: nil, config: MutationTester.configuration, since: nil, changed_files: nil)
      raise ArgumentError, 'provide exactly one of glob: or files:' unless glob.nil? ^ files.nil?

      @glob = glob
      @files = files
      @spec_template = spec_template.nil? || spec_template.empty? ? DEFAULT_SPEC_TEMPLATE : spec_template
      @config = config
      @since = since
      @changed_files = changed_files
    end

    def run
      sources = @files ? @files.uniq : Dir.glob(@glob).select { |path| File.file?(path) }.sort
      if sources.empty?
        puts Rainbow("❌ No source files matched glob: #{@glob}").red if @glob
        return Result.new(processed: [], skipped: [], unchanged: [])
      end

      sources, unchanged = partition_by_change(sources)
      if sources.empty?
        puts Rainbow("✓ Nothing to mutate: none of the #{unchanged.size} matched files changed since #{@since}.").green
        return Result.new(processed: [], skipped: [], unchanged: unchanged)
      end

      processed = []
      skipped = []
      interrupted = false

      sources.each do |source_file|
        outcome = classify(source_file)
        if outcome.is_a?(SkippedEntry)
          skipped << outcome
          next
        end

        entry, interrupted = run_one(source_file, outcome)
        processed << entry
        break if interrupted
      end

      result = Result.new(processed: processed, skipped: skipped, unchanged: unchanged, interrupted: interrupted)
      print_summary(result)
      result
    end

    def classify(source_file)
      if @files
        return SkippedEntry.new(source_file: source_file, reason: :missing) unless File.file?(source_file)
        return SkippedEntry.new(source_file: source_file, reason: :not_ruby) unless source_file.end_with?('.rb')
        return SkippedEntry.new(source_file: source_file, reason: :test_file) if self.class.test_file?(source_file)
      end

      spec_file = spec_path_for(source_file)
      return SkippedEntry.new(source_file: source_file, expected_spec: spec_file, reason: :no_spec) unless File.exist?(spec_file)

      spec_file
    end

    private

    def partition_by_change(sources)
      return [sources, []] if @changed_files.nil?

      sources.partition { |source| @changed_files.include?(File.expand_path(source)) }
    end

    def run_one(source_file, spec_file)
      print_separator(source_file, spec_file)
      file_config = @config.merge(output_dir: report_subdir_for(source_file))
      core = Core.new(source_file, spec_file, file_config)
      passed = core.run
      entry = ProcessedEntry.new(
        source_file: source_file,
        spec_file: spec_file,
        score: core.mutation_score,
        passed: passed,
        output_dir: file_config.output_dir,
        results: core.results,
        interrupted: core.interrupted?,
        degraded: core.infrastructure_failure?
      )
      [entry, core.interrupted?]
    end

    def spec_path_for(source_file)
      @spec_template.gsub(NAME_PLACEHOLDER, source_name(source_file))
    end

    def source_name(source_file)
      source_file.sub(%r{\A\./}, '').sub(%r{\Alib/}, '').sub(/\.rb\z/, '')
    end

    def report_subdir_for(source_file)
      slug = source_file.gsub(/[^0-9A-Za-z]+/, '_').gsub(/\A_+|_+\z/, '')
      digest = Digest::SHA256.hexdigest(source_file)[0, 10]
      File.join(@config.output_dir, "#{slug}_#{digest}")
    end

    def print_separator(source_file, spec_file)
      puts
      puts Rainbow('=' * 80).bright
      puts Rainbow("Testing: #{source_file}").cyan
      puts Rainbow("Spec:    #{spec_file}").cyan
      puts Rainbow('=' * 80).bright
    end

    def print_summary(result)
      puts
      puts Rainbow('=' * 80).bright
      unchanged_note = (result.unchanged || []).empty? ? '' : ", #{result.unchanged.size} unchanged since #{@since}"
      puts Rainbow("📦 Batch summary: #{result.processed.size} processed, #{result.skipped.size} skipped#{unchanged_note}").bright.cyan
      puts Rainbow('=' * 80).bright

      result.processed.each do |entry|
        status = entry.passed? ? Rainbow('PASS').green : Rainbow('FAIL').red
        puts "#{status}  #{format('%6.2f', entry.score)}%  #{entry.source_file}"
      end

      print_skipped(result.skipped)

      unless (result.unchanged || []).empty?
        puts Rainbow('-' * 80).faint
        puts Rainbow("SKIPPED (unchanged since #{@since}):").yellow
        result.unchanged.each do |source_file|
          puts Rainbow("  - #{source_file}").yellow
        end
      end

      if result.interrupted?
        puts Rainbow('-' * 80).faint
        puts Rainbow('🛑 Batch interrupted by --fail-fast: a mutant survived; remaining files were not run.').red
      end

      puts Rainbow('=' * 80).bright
      failed = result.processed.reject(&:passed?)
      degraded = failed.select(&:degraded?)
      if @files && result.processed.empty?
        puts Rainbow('❌ No files were mutation-tested: every listed file was skipped').red
      elsif result.success?
        puts Rainbow('✓ All processed files met the mutation score threshold').green
      elsif degraded.size == failed.size
        puts Rainbow('❌ The failing files produced no scored mutants; this indicates an infrastructure or runner problem, not a test-quality gap').red
      else
        puts Rainbow('❌ One or more files did not meet the mutation score threshold').red
        unless degraded.empty?
          puts Rainbow("⚠️ #{degraded.size} of the failing files produced no scored mutants (infrastructure or runner problem); see the per-file output above").yellow
        end
      end

      print_survivors(result.survivors)
    end

    def print_survivors(survivors)
      return if survivors.empty?

      puts Rainbow('-' * 80).faint
      puts Rainbow("🧟 Surviving mutants (#{survivors.size}):").red
      survivors.each do |survivor|
        puts Rainbow("  #{survivor[:file]}:#{survivor[:line]} #{survivor[:original]} -> #{survivor[:mutated]}").red
      end
      puts Rainbow('A surviving mutant is a change to your code that your tests do not detect; add or strengthen a test that fails on it.').yellow
    end

    def print_skipped(skipped)
      SKIP_ORDER.each do |reason|
        entries = skipped.select { |entry| (entry.reason || :no_spec) == reason }
        next if entries.empty?

        puts Rainbow('-' * 80).faint
        puts Rainbow("SKIPPED (#{SKIP_REASONS.fetch(reason)}):").yellow
        entries.each do |entry|
          suffix = entry.expected_spec ? " (expected #{entry.expected_spec})" : ''
          puts Rainbow("  - #{entry.source_file}#{suffix}").yellow
        end
      end
    end
  end
end
