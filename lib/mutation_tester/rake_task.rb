require 'rake'

module MutationTester
  RAKE_TASKS_PATH = File.expand_path('../tasks/mutation_tester.rake', __dir__)
  BENCH_TASKS_PATH = File.expand_path('../tasks/bench.rake', __dir__)

  @rake_tasks_loaded = false

  def self.load_rake_tasks
    return if @rake_tasks_loaded

    @rake_tasks_loaded = true
    load RAKE_TASKS_PATH
    load BENCH_TASKS_PATH if File.exist?(BENCH_TASKS_PATH)
  end
end

MutationTester.load_rake_tasks
