require 'fileutils'
require 'tmpdir'

task :environment unless Rake::Task.task_defined?(:environment)

module MutationTester
  module Bench
    def self.root
      File.expand_path('../..', __dir__)
    end

    def self.output_dir
      File.expand_path(File.join('tmp', 'bench'))
    end

    def self.reference_results
      [
        { benchmark: 'pricer_weak', mutations: 106, survivors: 26, score: '75.47' },
        { benchmark: 'calculator_weak', mutations: 57, survivors: 5, score: '91.23' },
        { benchmark: 'calculator_complete', mutations: 57, survivors: 0, score: '100.00' }
      ]
    end

    def self.definitions
      require File.join(root, 'spec', 'support', 'bench_pricer_fixture')
      calculator = File.read(File.join(root, 'examples', 'calculator.rb'))
      [
        {
          name: 'pricer_weak',
          description: 'benchmark A Basket::Pricer from spec/support/bench_pricer_fixture.rb with its gap-riddled weak spec',
          files: {
            'lib/basket/pricer.rb' => BenchPricerFixture::SOURCE,
            'spec/basket/pricer_spec.rb' => BenchPricerFixture::WEAK_SPEC,
            'spec/spec_helper.rb' => BenchPricerFixture::SPEC_HELPER
          },
          source: 'lib/basket/pricer.rb',
          spec: 'spec/basket/pricer_spec.rb'
        },
        {
          name: 'calculator_weak',
          description: 'examples/calculator.rb with the weak examples/calculator_spec.rb',
          files: {
            'calculator.rb' => calculator,
            'calculator_spec.rb' => File.read(File.join(root, 'examples', 'calculator_spec.rb'))
          },
          source: 'calculator.rb',
          spec: 'calculator_spec.rb'
        },
        {
          name: 'calculator_complete',
          description: 'examples/calculator.rb with the complete examples/calculator_100_perc_spec.rb',
          files: {
            'calculator.rb' => calculator,
            'calculator_100_perc_spec.rb' => File.read(File.join(root, 'examples', 'calculator_100_perc_spec.rb'))
          },
          source: 'calculator.rb',
          spec: 'calculator_100_perc_spec.rb'
        }
      ]
    end

    def self.build_project(definition, dir)
      definition[:files].each do |relative_path, content|
        path = File.join(dir, relative_path)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
      end
      system('git', 'init', '--quiet', dir, out: File::NULL, err: File::NULL, exception: true)
    end

    def self.run_benchmark(definition)
      Dir.mktmpdir('mutation_tester_bench') do |dir|
        build_project(definition, dir)
        config = Configuration.new
        config.reporters = []
        config.fail_on_threshold = false
        core = Core.new(File.join(dir, definition[:source]), File.join(dir, definition[:spec]), config)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        completed = Dir.chdir(dir) { core.run }
        wall_seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        json = Reporters::JsonReporter.new(core.results, core.source_file, core.spec_file, config).render
        {
          name: definition[:name],
          description: definition[:description],
          results: core.results,
          completed: completed,
          wall_seconds: wall_seconds,
          json: "#{json}\n"
        }
      end
    end

    def self.taxonomy(results)
      %i[killed survived timeout stillborn error].to_h do |status|
        [status, results.count { |result| Reporters::BaseReporter.status_for(result) == status }]
      end
    end

    def self.normalized_survivors(results)
      results
        .select { |result| Reporters::BaseReporter.status_for(result) == :survived }
        .map { |result| [result[:line].to_i, result[:type].to_s, result[:original].to_s, result[:mutated].to_s] }
        .sort
        .map { |tuple| tuple.join('|') }
    end

    def self.score(results)
      format('%.2f', Reporters::BaseReporter.score(results))
    end

    def self.summary_markdown(runs)
      lines = ['# Benchmark rerun', '']
      lines << "Produced by `rake \"bench:rerun\"` with mutation_tester #{VERSION} and the default runner."
      lines << 'Wall time is measured with a monotonic clock around each in-process run.'
      lines << ''
      lines << '## Benchmarks'
      lines << ''
      runs.each { |run| lines << "- #{run[:name]}: #{run[:description]}" }
      lines << ''
      lines << '## Results'
      lines << ''
      lines << '| Benchmark | Mutations | Killed | Survived | Timeout | Stillborn | Error | Score | Wall [s] |'
      lines << '|---|---|---|---|---|---|---|---|---|'
      runs.each do |run|
        counts = taxonomy(run[:results])
        cells = [run[:name], run[:results].size, counts[:killed], counts[:survived], counts[:timeout],
                 counts[:stillborn], counts[:error], score(run[:results]), format('%.2f', run[:wall_seconds])]
        lines << "| #{cells.join(' | ')} |"
      end
      lines << ''
      lines << '## Reference values'
      lines << ''
      lines << 'Pinned from the 2026-07-13 rerun report on main after E12S01, as documentation only:'
      lines << ''
      lines << '| Benchmark | Mutations | Survivors | Score |'
      lines << '|---|---|---|---|'
      reference_results.each do |reference|
        lines << "| #{reference[:benchmark]} | #{reference[:mutations]} | #{reference[:survivors]} | #{reference[:score]} |"
      end
      runs.each do |run|
        lines << ''
        lines << "## Survivors: #{run[:name]}"
        lines << ''
        survivors = normalized_survivors(run[:results])
        if survivors.empty?
          lines << 'none'
        else
          lines << '```'
          lines.concat(survivors)
          lines << '```'
        end
      end
      "#{lines.join("\n")}\n"
    end
  end
end

namespace :bench do
  desc 'Rerun the pricer and calculator benchmarks and write report artifacts under tmp/bench (usage: rake "bench:rerun")'
  task :rerun do
    require 'mutation_tester'

    output_dir = MutationTester::Bench.output_dir
    FileUtils.mkdir_p(output_dir)

    runs = MutationTester::Bench.definitions.map do |definition|
      run = MutationTester::Bench.run_benchmark(definition)
      abort("Benchmark #{run[:name]} did not complete a full run; no artifacts were written for it.") unless run[:completed]
      File.write(File.join(output_dir, "#{run[:name]}.json"), run[:json])
      run
    end

    File.write(File.join(output_dir, 'summary.md'), MutationTester::Bench.summary_markdown(runs))

    puts Rainbow("\n✓ Benchmark artifacts written to #{output_dir}").green
    runs.each do |run|
      counts = MutationTester::Bench.taxonomy(run[:results])
      puts "  #{run[:name]}: #{run[:results].size} mutations, #{counts[:survived]} survived, " \
           "score #{MutationTester::Bench.score(run[:results])}, wall #{format('%.2f', run[:wall_seconds])} s"
    end
  end
end
