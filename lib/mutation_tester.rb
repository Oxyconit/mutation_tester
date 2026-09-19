require 'parser/current'
require 'unparser'
require 'parallel'
require 'rainbow'
require 'fileutils'
require 'erb'
require 'json'
require 'io/console'

require_relative 'mutation_tester/version'
require_relative 'mutation_tester/configuration'
require_relative 'mutation_tester/framework_detector'
require_relative 'mutation_tester/in_memory_loader'
require_relative 'mutation_tester/fork_runner'
require_relative 'mutation_tester/test_command'
require_relative 'mutation_tester/core'
require_relative 'mutation_tester/batch_runner'
require_relative 'mutation_tester/mutator'
require_relative 'mutation_tester/mutation_runner'
require_relative 'mutation_tester/reporters/base_reporter'
require_relative 'mutation_tester/reporters/console_reporter'
require_relative 'mutation_tester/reporters/html_reporter'
require_relative 'mutation_tester/reporters/json_reporter'
require_relative 'mutation_tester/reporters/batch_json_reporter'
require_relative 'mutation_tester/progress_display'

require_relative 'mutation_tester/railtie' if defined?(Rails::Railtie)

module MutationTester
  class Error < StandardError; end

  class << self
    attr_writer :configuration

    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    def reset_configuration!
      @configuration = Configuration.new
    end

    def run(source_file, spec_file, options = {})
      config = configuration.merge(options)
      core = Core.new(source_file, spec_file, config)
      core.run
    end
  end
end
