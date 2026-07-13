module MutationTester
  class Railtie < Rails::Railtie
    rake_tasks do
      require_relative 'rake_task'
    end
  end
end
