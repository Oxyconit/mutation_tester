require 'spec_helper'
require 'tmpdir'

RSpec.describe MutationTester::TestCommand do
  describe '.detect_framework' do
    it 'detects minitest by *_test.rb suffix' do
      expect(described_class.detect_framework('foo_test.rb')).to eq(:minitest)
    end

    it 'detects minitest by test_* prefix' do
      expect(described_class.detect_framework('test_foo.rb')).to eq(:minitest)
    end

    it 'detects rspec by *_spec.rb suffix' do
      expect(described_class.detect_framework('foo_spec.rb')).to eq(:rspec)
    end

    it 'falls back to content when the filename is ambiguous' do
      allow(File).to receive(:exist?).and_return(true)
      allow(File).to receive(:read).and_return("require 'minitest'")
      expect(described_class.detect_framework('foo.rb')).to eq(:minitest)
    end

    it 'defaults to rspec for an ambiguous filename with no minitest require' do
      allow(File).to receive(:exist?).and_return(true)
      allow(File).to receive(:read).and_return("puts 'hello'")
      expect(described_class.detect_framework('foo.rb')).to eq(:rspec)
    end
  end

  describe '.use_bundle_exec?' do
    let(:tmp_dir) { Dir.mktmpdir }

    after { FileUtils.remove_entry(tmp_dir) }

    it 'is true when a Gemfile exists in a parent directory' do
      FileUtils.touch(File.join(tmp_dir, 'Gemfile'))
      lib_dir = File.join(tmp_dir, 'lib')
      FileUtils.mkdir_p(lib_dir)

      expect(described_class.use_bundle_exec?(File.join(lib_dir, 'foo.rb'))).to be true
    end

    it 'is false when no Gemfile exists up the tree' do
      lib_dir = File.join(tmp_dir, 'lib')
      FileUtils.mkdir_p(lib_dir)

      expect(described_class.use_bundle_exec?(File.join(lib_dir, 'foo.rb'))).to be false
    end
  end

  describe '#command' do
    it 'builds a bundle exec rspec command' do
      cmd = described_class.new('spec/foo_spec.rb', use_bundle_exec: true)
      expect(cmd.command).to eq('bundle exec rspec spec/foo_spec.rb')
    end

    it 'builds a bare rspec command when bundle exec is disabled' do
      cmd = described_class.new('spec/foo_spec.rb', use_bundle_exec: false)
      expect(cmd.command).to eq('rspec spec/foo_spec.rb')
    end

    it 'uses ruby as the runner for minitest' do
      cmd = described_class.new('test/foo_test.rb', use_bundle_exec: true)
      expect(cmd.command).to eq('bundle exec ruby test/foo_test.rb')
    end
  end

  describe '#argv' do
    it 'builds a bundle exec rspec argv array' do
      cmd = described_class.new('spec/foo_spec.rb', use_bundle_exec: true)
      expect(cmd.argv).to eq(['bundle', 'exec', 'rspec', 'spec/foo_spec.rb'])
    end

    it 'builds a bare rspec argv array when bundle exec is disabled' do
      cmd = described_class.new('spec/foo_spec.rb', use_bundle_exec: false)
      expect(cmd.argv).to eq(['rspec', 'spec/foo_spec.rb'])
    end

    it 'uses ruby as the runner for minitest' do
      cmd = described_class.new('test/foo_test.rb', use_bundle_exec: true)
      expect(cmd.argv).to eq(['bundle', 'exec', 'ruby', 'test/foo_test.rb'])
    end

    it 'keeps a path with spaces and shell metacharacters as one argv element' do
      cmd = described_class.new('spec/a b;c_spec.rb', use_bundle_exec: false)
      expect(cmd.argv).to eq(['rspec', 'spec/a b;c_spec.rb'])
      expect(cmd.argv.last).to eq('spec/a b;c_spec.rb')
    end

    it 'appends an -e pair per example filter for rspec' do
      cmd = described_class.new('spec/foo_spec.rb', use_bundle_exec: false, example_filters: ['#foo', '.foo'])
      expect(cmd.argv).to eq(['rspec', 'spec/foo_spec.rb', '-e', '#foo', '-e', '.foo'])
    end

    it 'keeps each example filter as one argv element' do
      cmd = described_class.new('spec/foo_spec.rb', use_bundle_exec: false, example_filters: ['#foo bar'])
      expect(cmd.argv.last).to eq('#foo bar')
    end

    it 'ignores example filters for minitest and runs the full file' do
      cmd = described_class.new('test/foo_test.rb', use_bundle_exec: false, example_filters: ['#foo'])
      expect(cmd.argv).to eq(['ruby', 'test/foo_test.rb'])
      expect(cmd.example_filters).to be_empty
    end

    it 'asks rspec to stop at the first failing example for a mutant run' do
      cmd = described_class.new('spec/foo_spec.rb', use_bundle_exec: false, stop_on_first_failure: true)
      expect(cmd.argv).to eq(['rspec', 'spec/foo_spec.rb', '--fail-fast'])
    end

    it 'preloads the fail-fast reporter before the file for a minitest mutant run' do
      cmd = described_class.new('test/foo_test.rb', use_bundle_exec: false, stop_on_first_failure: true)
      expect(cmd.argv).to eq(['ruby', '-r', described_class::MINITEST_FAIL_FAST_PATH, 'test/foo_test.rb'])
      expect(File.exist?(described_class::MINITEST_FAIL_FAST_PATH)).to be(true)
    end

    it 'runs the whole file when stopping at the first failure was not requested' do
      expect(described_class.new('spec/foo_spec.rb', use_bundle_exec: false).argv).not_to include('--fail-fast')
      expect(described_class.new('test/foo_test.rb', use_bundle_exec: false).argv).not_to include('-r')
    end
  end

  describe '#fork_execution?' do
    it 'defaults to the spawn path when no runner is given' do
      cmd = described_class.new('spec/foo_spec.rb', use_bundle_exec: false)
      expect(cmd.fork_execution?).to be(false)
    end

    it 'stays on spawn when the runner is spawn even though fork is available' do
      allow(MutationTester::ForkRunner).to receive(:available?).and_return(true)
      cmd = described_class.new('spec/foo_spec.rb', use_bundle_exec: false, runner: :spawn)
      expect(cmd.fork_execution?).to be(false)
    end

    it 'selects fork for rspec in auto mode when the platform can fork' do
      allow(MutationTester::ForkRunner).to receive(:available?).and_return(true)
      cmd = described_class.new('spec/foo_spec.rb', use_bundle_exec: false, runner: :auto)
      expect(cmd.fork_execution?).to be(true)
    end

    it 'falls back to spawn when the platform cannot fork even with an explicit fork runner' do
      allow(MutationTester::ForkRunner).to receive(:available?).and_return(false)
      cmd = described_class.new('spec/foo_spec.rb', use_bundle_exec: false, runner: :fork)
      expect(cmd.fork_execution?).to be(false)
    end

    it 'selects fork for minitest too when the platform can fork' do
      allow(MutationTester::ForkRunner).to receive(:available?).and_return(true)
      cmd = described_class.new('test/foo_test.rb', use_bundle_exec: false, runner: :fork)
      expect(cmd.fork_execution?).to be(true)
    end
  end

  describe '#run runner delegation' do
    it 'delegates a fork-mode run to the preloaded fork runner' do
      fork_runner = instance_double(MutationTester::ForkRunner)
      result = MutationTester::TestCommand::Result.new(true, false)
      allow(MutationTester::ForkRunner).to receive(:available?).and_return(true)
      allow(MutationTester::ForkRunner).to receive(:acquire)
        .with(use_bundle_exec: false, framework: :rspec).and_return(fork_runner)
      expect(fork_runner).to receive(:execute)
        .with('spec/foo_spec.rb', timeout: 5, chdir: Dir.pwd, capture: false, args: [], stop_on_first_failure: false)
        .and_return(result)

      cmd = described_class.new('spec/foo_spec.rb', use_bundle_exec: false, runner: :fork)
      expect(cmd.run(timeout: 5)).to equal(result)
    end

    it 'passes example filters to the fork runner as -e arguments' do
      fork_runner = instance_double(MutationTester::ForkRunner)
      result = MutationTester::TestCommand::Result.new(true, false)
      allow(MutationTester::ForkRunner).to receive(:available?).and_return(true)
      allow(MutationTester::ForkRunner).to receive(:acquire)
        .with(use_bundle_exec: false, framework: :rspec).and_return(fork_runner)
      expect(fork_runner).to receive(:execute)
        .with('spec/foo_spec.rb', timeout: 5, chdir: Dir.pwd, capture: false, args: ['-e', '#foo'], stop_on_first_failure: false)
        .and_return(result)

      cmd = described_class.new('spec/foo_spec.rb', use_bundle_exec: false, runner: :fork, example_filters: ['#foo'])
      expect(cmd.run(timeout: 5)).to equal(result)
    end

    it 'spawns a process when the fork runner cannot be acquired' do
      allow(MutationTester::ForkRunner).to receive(:available?).and_return(true)
      allow(MutationTester::ForkRunner).to receive(:acquire).and_return(nil)

      spawned = false
      allow(Process).to receive(:spawn).and_wrap_original do |original, *_args|
        spawned = true
        original.call('true')
      end

      cmd = described_class.new('spec/foo_spec.rb', use_bundle_exec: false, runner: :fork)
      result = cmd.run(timeout: 5)

      expect(spawned).to be(true)
      expect(result.passed?).to be(true)
    end
  end

  describe '#run shell-free execution' do
    it 'spawns the argv array, never a single shell command string' do
      cmd = described_class.new('spec/foo_spec.rb', use_bundle_exec: true)
      positional = nil

      allow(Process).to receive(:spawn).and_wrap_original do |original, *args|
        positional = args.reject { |a| a.is_a?(Hash) }
        original.call('true')
      end

      cmd.run

      expect(positional).to eq(['bundle', 'exec', 'rspec', 'spec/foo_spec.rb'])
      expect(positional.size).to be > 1
    end
  end

  describe '#run per-worker environment injection' do
    it 'prepends an env hash keyed on Parallel.worker_number when a worker-env var is set' do
      allow(Parallel).to receive(:worker_number).and_return(1)
      cmd = described_class.new('spec/foo_spec.rb', use_bundle_exec: false, worker_env_var: 'TEST_ENV_NUMBER')

      captured = nil
      allow(Process).to receive(:spawn).and_wrap_original do |original, *args|
        captured = args.first
        original.call('true')
      end

      cmd.run

      expect(captured).to eq('TEST_ENV_NUMBER' => '2')
    end

    it 'uses the empty first-worker value outside a parallel block' do
      allow(Parallel).to receive(:worker_number).and_return(nil)
      cmd = described_class.new('spec/foo_spec.rb', use_bundle_exec: false, worker_env_var: 'TEST_ENV_NUMBER')

      captured = nil
      allow(Process).to receive(:spawn).and_wrap_original do |original, *args|
        captured = args.first
        original.call('true')
      end

      cmd.run

      expect(captured).to eq('TEST_ENV_NUMBER' => '')
    end

    it 'prepends no env hash when no worker-env var is set' do
      cmd = described_class.new('spec/foo_spec.rb', use_bundle_exec: false)

      captured = nil
      allow(Process).to receive(:spawn).and_wrap_original do |original, *args|
        captured = args.first
        original.call('true')
      end

      cmd.run

      expect(captured).not_to be_a(Hash)
    end
  end

  describe '#run output capture' do
    let(:cmd) { described_class.new('spec/foo_spec.rb', use_bundle_exec: false) }

    before do
      allow(cmd).to receive(:argv)
        .and_return(['ruby', '-e', 'STDOUT.puts("cap-out"); STDERR.puts("cap-err")'])
    end

    it 'discards child output to File::NULL by default and exposes no captured output' do
      redirect_target = nil
      allow(Process).to receive(:spawn).and_wrap_original do |original, *args|
        redirect_target = args.last[%i[out err]]
        original.call(*args)
      end

      result = cmd.run

      expect(result.passed?).to be(true)
      expect(redirect_target).to eq(File::NULL)
      expect(result.output).to be_nil
    end

    it 'captures child stdout+stderr to a temp file, exposes it on the result, and cleans up' do
      capture_path = nil
      allow(Process).to receive(:spawn).and_wrap_original do |original, *args|
        capture_path = args.last[%i[out err]]
        original.call(*args)
      end

      result = cmd.run(capture: true)

      expect(result.passed?).to be(true)
      expect(result.output).to include('cap-out').and include('cap-err')
      expect(capture_path).to be_a(String)
      expect(capture_path).not_to eq(File::NULL)
      expect(File.exist?(capture_path)).to be(false)
    end
  end

  describe '#shell_command' do
    let(:cmd) { described_class.new('spec/foo_spec.rb', use_bundle_exec: true) }

    it 'returns the bare command with no wrapper by default' do
      expect(cmd.shell_command).to eq(cmd.command)
    end

    it 'prepends the timeout wrapper only' do
      expect(cmd.shell_command(timeout: 30)).to eq("timeout 30s #{cmd.command}")
    end

    it 'appends output redirection when quiet' do
      expect(cmd.shell_command(quiet: true)).to eq("#{cmd.command} > /dev/null 2>&1")
    end
  end

  describe 'baseline / mutant command parity' do
    let(:tmp_dir) { Dir.mktmpdir }
    let(:source_file) { File.join(tmp_dir, 'lib', 'calc.rb') }
    let(:spec_file) { File.join(tmp_dir, 'spec', 'calc_spec.rb') }

    before do
      FileUtils.mkdir_p(File.dirname(source_file))
      FileUtils.mkdir_p(File.dirname(spec_file))
      FileUtils.touch(File.join(tmp_dir, 'Gemfile'))
      FileUtils.touch(source_file)
      FileUtils.touch(spec_file)
    end

    after { FileUtils.remove_entry(tmp_dir) }

    def build_command
      described_class.new(
        spec_file,
        use_bundle_exec: described_class.use_bundle_exec?(source_file)
      )
    end

    it 'produces an identical command for baseline and mutant' do
      baseline = build_command
      mutant = build_command

      expect(baseline.command).to eq(mutant.command)
    end

    it 'produces an identical argv for baseline and mutant' do
      baseline = build_command
      mutant = build_command

      expect(baseline.argv).to eq(mutant.argv)
    end

    it 'differs only by the timeout wrapper when running a mutant' do
      baseline = build_command.command
      mutant = build_command.shell_command(timeout: 30, quiet: true)

      expect(mutant).to eq("timeout 30s #{baseline} > /dev/null 2>&1")
    end
  end

  describe '#wait_with_deadline race at the deadline boundary' do
    let(:cmd) { described_class.new('spec/foo_spec.rb', use_bundle_exec: false) }
    let(:pid) { 4242 }

    def status_double(success)
      instance_double(Process::Status, success?: success)
    end

    before do
      allow(cmd).to receive(:monotonic_time).and_return(0, 5)
      allow(cmd).to receive(:process_running?).with(pid).and_return(false)
    end

    it 'reports a child that finishes at the boundary by its real success status, not timeout' do
      allow(Process).to receive(:waitpid2)
        .with(pid, Process::WNOHANG)
        .and_return(nil, [pid, status_double(true)])
      expect(cmd).not_to receive(:terminate_process_group)

      result = cmd.send(:wait_with_deadline, pid, 5)

      expect(result.passed?).to be(true)
      expect(result.timed_out?).to be(false)
    end

    it 'reports a child that fails at the boundary as killed (not passed, not timeout)' do
      allow(Process).to receive(:waitpid2)
        .with(pid, Process::WNOHANG)
        .and_return(nil, [pid, status_double(false)])
      expect(cmd).not_to receive(:terminate_process_group)

      result = cmd.send(:wait_with_deadline, pid, 5)

      expect(result.passed?).to be(false)
      expect(result.timed_out?).to be(false)
    end

    it 'still times out and kills the group when the child is genuinely alive at the deadline' do
      allow(Process).to receive(:waitpid2)
        .with(pid, Process::WNOHANG)
        .and_return(nil, nil)
      expect(cmd).to receive(:terminate_process_group).with(pid)

      result = cmd.send(:wait_with_deadline, pid, 5)

      expect(result.passed?).to be(false)
      expect(result.timed_out?).to be(true)
    end
  end
end
