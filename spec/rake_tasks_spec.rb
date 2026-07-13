require 'spec_helper'
require 'rake'
require 'stringio'
require 'mutation_tester/rake_task'

RSpec.describe 'mutation_tester rake tasks' do
  RAKE_FILE = File.expand_path('../lib/tasks/mutation_tester.rake', __dir__)
  SRC = File.expand_path('../examples/calculator.rb', __dir__)
  SPEC = File.expand_path('../examples/calculator_spec.rb', __dir__)

  before do
    @original_application = Rake.application
    Rake.application = Rake::Application.new
    MutationTester.instance_variable_set(:@rake_tasks_loaded, false)
  end

  after do
    Rake.application = @original_application
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  describe 'public entrypoint loads the tasks and guards double definition' do
    it 'defines both the top-level and namespaced tasks' do
      MutationTester.load_rake_tasks

      expect(Rake::Task.task_defined?('mutation_test')).to be(true)
      expect(Rake::Task.task_defined?('mutation:test')).to be(true)
    end

    it 'does not define a task twice when the loader runs more than once' do
      MutationTester.load_rake_tasks
      MutationTester.load_rake_tasks

      expect(Rake::Task['mutation_test'].actions.size).to eq(1)
    end
  end

  describe 'conditional :environment prerequisite' do
    it 'defines a no-op :environment task when none exists (non-Rails)' do
      MutationTester.load_rake_tasks

      expect(Rake::Task.task_defined?('environment')).to be(true)
    end

    it 'leaves a pre-existing :environment task untouched (Rails)' do
      ran = []
      Rake::Task.define_task(:environment) { ran << :rails_env }

      MutationTester.load_rake_tasks
      Rake::Task['environment'].invoke

      expect(ran).to eq([:rails_env])
    end
  end

  %w[mutation:test mutation_test].each do |task_name|
    describe "#{task_name} validates its arguments and delegates to MutationTester.run" do
      before { MutationTester.load_rake_tasks }

      let(:task) { Rake::Task[task_name] }

      it 'aborts with a usage message when no arguments are given' do
        out = capture_stdout do
          expect { task.invoke }.to raise_error(SystemExit)
        end

        expect(out).to match(/Usage:/)
      end

      it 'aborts when the source file does not exist' do
        out = capture_stdout do
          expect { task.invoke('does_not_exist.rb', SPEC) }.to raise_error(SystemExit)
        end

        expect(out).to match(/not found/i)
      end

      it 'aborts when the spec file does not exist' do
        out = capture_stdout do
          expect { task.invoke(SRC, 'does_not_exist_spec.rb') }.to raise_error(SystemExit)
        end

        expect(out).to match(/not found/i)
      end

      it 'delegates to MutationTester.run with the given files when both exist' do
        allow(MutationTester).to receive(:run).and_return(true)

        capture_stdout do
          expect { task.invoke(SRC, SPEC) }.not_to raise_error
        end

        expect(MutationTester).to have_received(:run).with(SRC, SPEC)
      end

      it 'aborts when MutationTester.run reports failure' do
        allow(MutationTester).to receive(:run).and_return(false)

        capture_stdout do
          expect { task.invoke(SRC, SPEC) }.to raise_error(SystemExit)
        end

        expect(MutationTester).to have_received(:run).with(SRC, SPEC)
      end
    end
  end
end
