require 'spec_helper'
require 'tmpdir'

RSpec.describe MutationTester::ForkRunner do
  after { described_class.shutdown_all }

  def worker_pid(runner)
    runner.instance_variable_get(:@pid)
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def dead_within?(pid, grace)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + grace
    loop do
      return true unless process_alive?(pid)
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
    end
  end

  describe '.acquire' do
    it 'returns nil when the platform cannot fork' do
      allow(described_class).to receive(:available?).and_return(false)

      expect(described_class.acquire(use_bundle_exec: false)).to be_nil
    end

    it 'returns nil with a warning when the worker fails to preload' do
      stub_const('MutationTester::ForkRunner::WORKER_PATH', File::NULL)

      runner = nil
      expect { runner = described_class.acquire(use_bundle_exec: false) }
        .to output(/falling back to spawn/).to_stderr

      expect(runner).to be_nil
    end

    it 'reuses one preloaded worker per process for repeated runs' do
      first = described_class.acquire(use_bundle_exec: false)
      second = described_class.acquire(use_bundle_exec: false)

      expect(first).not_to be_nil
      expect(second).to equal(first)
    end
  end

  describe '.prepare_pool' do
    it 'forks ready clones from the preloaded primary without spawning new worker processes' do
      primary = described_class.acquire(use_bundle_exec: false)
      expect(primary).not_to be_nil

      expect(Process).not_to receive(:spawn)
      runners = described_class.prepare_pool(2, use_bundle_exec: false)

      expect(runners.compact.size).to eq(2)
      expect(runners).to all(be_ready)
      expect(runners.map { |r| worker_pid(r) }).not_to include(worker_pid(primary))
    end

    it 'runs pass, fail and timeout jobs through a pooled clone' do
      Dir.mktmpdir do |dir|
        pass_spec = File.join(dir, 'pass_spec.rb')
        File.write(pass_spec, "RSpec.describe(1) { it('t') { expect(1).to eq(1) } }\n")
        fail_spec = File.join(dir, 'fail_spec.rb')
        File.write(fail_spec, "RSpec.describe(1) { it('t') { expect(1).to eq(2) } }\n")
        loop_spec = File.join(dir, 'loop_spec.rb')
        File.write(loop_spec, "while true; end\n")

        clone = described_class.prepare_pool(1, use_bundle_exec: false).first

        expect(clone.execute(pass_spec, timeout: 30).passed?).to be(true)
        expect(clone.execute(fail_spec, timeout: 30).passed?).to be(false)

        looping = clone.execute(loop_spec, timeout: 2)
        expect(looping.passed?).to be(false)
        expect(looping.timed_out?).to be(true)
      end
    end

    it 'hands each parallel worker its own preloaded clone instead of booting one per worker' do
      runners = described_class.prepare_pool(2, use_bundle_exec: false)
      pool_pids = runners.map { |r| worker_pid(r) }

      used = Parallel.map([0, 1], in_processes: 2) do |_item|
        sleep 0.1
        worker_pid(described_class.acquire(use_bundle_exec: false))
      end

      expect(used - pool_pids).to be_empty
      expect(used.uniq.size).to eq(2)
    end

    it 'replaces a dead discarded slot with a fresh ready clone on the next prepare_pool call' do
      first = described_class.prepare_pool(2, use_bundle_exec: false)
      dead = first[0]
      kept = first[1]
      dead.shutdown
      described_class.discard(dead)
      expect(described_class.pool[false][:runners][0]).to be_nil

      refilled = described_class.prepare_pool(2, use_bundle_exec: false)

      expect(refilled.compact.size).to eq(2)
      expect(refilled).to all(be_ready)
      expect(refilled[1]).to equal(kept)
    end

    it 'hands each pooled clone its own environment value from env_for' do
      Dir.mktmpdir do |dir|
        probe_spec = File.join(dir, 'probe_spec.rb')
        File.write(probe_spec, <<~RUBY)
          RSpec.describe('probe') do
            it('records the worker env value') do
              File.write(File.join(#{dir.inspect}, "seen-\#{ENV['MT_ENV_PROBE']}.txt"), 'x')
              expect(1).to eq(1)
            end
          end
        RUBY

        runners = described_class.prepare_pool(
          2,
          use_bundle_exec: false,
          env_for: ->(index) { { 'MT_ENV_PROBE' => MutationTester::Configuration.worker_env_value(index) } }
        )

        runners[0].execute(probe_spec, timeout: 30)
        runners[1].execute(probe_spec, timeout: 30)

        expect(File.exist?(File.join(dir, 'seen-.txt'))).to be(true)
        expect(File.exist?(File.join(dir, 'seen-2.txt'))).to be(true)
      end
    end

    it 'sets no per-worker environment value when env_for is omitted' do
      Dir.mktmpdir do |dir|
        probe_spec = File.join(dir, 'probe_spec.rb')
        File.write(probe_spec, <<~RUBY)
          RSpec.describe('probe') do
            it('records the worker env value') do
              File.write(File.join(#{dir.inspect}, "plain-\#{ENV['MT_ENV_PROBE']}.txt"), 'x')
              expect(1).to eq(1)
            end
          end
        RUBY

        runners = described_class.prepare_pool(2, use_bundle_exec: false)

        runners[0].execute(probe_spec, timeout: 30)
        runners[1].execute(probe_spec, timeout: 30)

        expect(File.exist?(File.join(dir, 'plain-.txt'))).to be(true)
        expect(File.exist?(File.join(dir, 'plain-2.txt'))).to be(false)
      end
    end

    it 'falls back to booting a fresh worker when the pooled clone was discarded' do
      clone = described_class.prepare_pool(1, use_bundle_exec: false).first
      clone.shutdown
      described_class.discard(clone)
      described_class.registry.delete([Process.pid, false])
      allow(Parallel).to receive(:worker_number).and_return(0)

      fresh = described_class.acquire(use_bundle_exec: false)

      expect(fresh).not_to be_nil
      expect(worker_pid(fresh)).not_to eq(worker_pid(clone))
    end
  end

  describe 'in-memory pool' do
    def write_fixture(dir)
      source = File.join(dir, 'thing.rb')
      File.write(source, "class Thing\n  def val\n    1\n  end\nend\n")
      spec = File.join(dir, 'thing_spec.rb')
      File.write(spec, <<~RUBY)
        require_relative 'thing'

        RSpec.describe Thing do
          it('reads the value') { expect(Thing.new.val).to eq(1) }
        end
      RUBY
      [source, spec]
    end

    it 'forks spec-preloaded clones that answer in-memory jobs, invisible to the file-based checkout' do
      Dir.mktmpdir do |dir|
        source, spec = write_fixture(dir)
        primary = described_class.new(use_bundle_exec: false)
        begin
          expect(primary.preload(spec, chdir: dir).first).to be(true)

          clones = described_class.prepare_in_memory_pool(2, primary)
          expect(clones.compact.size).to eq(2)

          surviving = clones[0].execute_in_memory(source: "class Thing\n  def val\n    1\n  end\nend\n", path: source, timeout: 30, chdir: dir)
          killed = clones[1].execute_in_memory(source: "class Thing\n  def val\n    2\n  end\nend\n", path: source, timeout: 30, chdir: dir)

          expect(surviving.status).to eq('pass')
          expect(killed.status).to eq('fail')

          allow(Parallel).to receive(:worker_number).and_return(1)
          expect(described_class.checkout_in_memory).to equal(clones[1])
          expect(described_class.pool[false]).to be_nil
          expect(described_class.acquire(use_bundle_exec: false)).not_to equal(clones[1])
        ensure
          primary.shutdown
        end
      end
    end

    it 'replaces a dead in-memory slot on the next prepare call and shuts pooled clones down before reuse' do
      Dir.mktmpdir do |dir|
        _source, spec = write_fixture(dir)
        primary = described_class.new(use_bundle_exec: false)
        begin
          primary.preload(spec, chdir: dir)
          clones = described_class.prepare_in_memory_pool(2, primary)
          dead = clones[0]
          dead.shutdown
          described_class.discard(dead)

          refilled = described_class.prepare_in_memory_pool(2, primary)
          expect(refilled.compact.size).to eq(2)
          expect(refilled).to all(be_ready)
          expect(refilled[1]).to equal(clones[1])

          pids = refilled.map { |clone| worker_pid(clone) }
          described_class.shutdown_in_memory_pool
          pids.each { |pid| expect(dead_within?(pid, 5)).to be(true) }
          expect(described_class.in_memory_pool_prepared?).to be(false)
        ensure
          primary.shutdown
        end
      end
    end
  end

  describe '#execute' do
    it 'reports a passing spec, a failing spec and a timed-out spec through one worker' do
      Dir.mktmpdir do |dir|
        pass_spec = File.join(dir, 'pass_spec.rb')
        File.write(pass_spec, "RSpec.describe(1) { it('t') { expect(1).to eq(1) } }\n")
        fail_spec = File.join(dir, 'fail_spec.rb')
        File.write(fail_spec, "RSpec.describe(1) { it('t') { expect(1).to eq(2) } }\n")
        loop_spec = File.join(dir, 'loop_spec.rb')
        File.write(loop_spec, "while true; end\n")

        runner = described_class.acquire(use_bundle_exec: false)

        passing = runner.execute(pass_spec, timeout: 30)
        expect(passing.passed?).to be(true)
        expect(passing.timed_out?).to be(false)

        failing = runner.execute(fail_spec, timeout: 30)
        expect(failing.passed?).to be(false)
        expect(failing.timed_out?).to be(false)

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        looping = runner.execute(loop_spec, timeout: 2)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        expect(looping.passed?).to be(false)
        expect(looping.timed_out?).to be(true)
        expect(elapsed).to be < 7

        recovered = runner.execute(pass_spec, timeout: 30)
        expect(recovered.passed?).to be(true)
      end
    end

    it 'captures the run output when asked, keeping pass detection intact' do
      Dir.mktmpdir do |dir|
        pass_spec = File.join(dir, 'pass_spec.rb')
        File.write(pass_spec, "RSpec.describe(1) { it('t') { expect(1).to eq(1) } }\n")

        runner = described_class.acquire(use_bundle_exec: false)
        result = runner.execute(pass_spec, timeout: 30, capture: true)

        expect(result.passed?).to be(true)
        expect(result.output).to include('1 example, 0 failures')
      end
    end

    it 'raises a MutationTester::Error when the worker dies mid-run' do
      Dir.mktmpdir do |dir|
        pass_spec = File.join(dir, 'pass_spec.rb')
        File.write(pass_spec, "RSpec.describe(1) { it('t') { expect(1).to eq(1) } }\n")

        runner = described_class.acquire(use_bundle_exec: false)
        Process.kill('KILL', worker_pid(runner))

        expect { runner.execute(pass_spec, timeout: 30) }
          .to raise_error(MutationTester::Error, /terminated unexpectedly/)
        expect(described_class.registry.values).not_to include(runner)
      end
    end
  end

  describe 'interrupt safety' do
    it 'does not orphan a running forked mutant when shut down mid-run' do
      Dir.mktmpdir do |dir|
        loop_spec = File.join(dir, 'loop_spec.rb')
        File.write(loop_spec, "while true; end\n")

        runner = described_class.acquire(use_bundle_exec: false)
        thread = Thread.new do
          begin
            runner.execute(loop_spec, timeout: 600)
          rescue MutationTester::Error, IOError
            nil
          end
        end

        child_pid = nil
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
        loop do
          child_pid = runner.instance_variable_get(:@current_child)
          break if child_pid
          break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          sleep 0.05
        end
        expect(child_pid).not_to be_nil

        worker = worker_pid(runner)
        described_class.shutdown_all
        thread.join(5)

        expect(dead_within?(worker, 5)).to be(true)
        expect(dead_within?(child_pid, 5)).to be(true)
      end
    end
  end

  describe '.shutdown_all' do
    it 'terminates the preloaded worker and clears the registry for this process' do
      runner = described_class.acquire(use_bundle_exec: false)
      pid = worker_pid(runner)
      expect(process_alive?(pid)).to be(true)

      described_class.shutdown_all

      expect(process_alive?(pid)).to be(false)
      expect(described_class.registry.keys.map(&:first)).not_to include(Process.pid)
    end

    it 'terminates the pooled clones together with the primary and clears the pool' do
      clones = described_class.prepare_pool(2, use_bundle_exec: false)
      pids = ([described_class.acquire(use_bundle_exec: false)] + clones).map { |r| worker_pid(r) }
      pids.each { |pid| expect(process_alive?(pid)).to be(true) }

      described_class.shutdown_all

      pids.each { |pid| expect(dead_within?(pid, 5)).to be(true) }
      expect(described_class.pool).to be_empty
    end

    it 'does not orphan a running forked mutant inside a pooled clone when shut down mid-run' do
      Dir.mktmpdir do |dir|
        loop_spec = File.join(dir, 'loop_spec.rb')
        File.write(loop_spec, "while true; end\n")

        clone = described_class.prepare_pool(1, use_bundle_exec: false).first
        thread = Thread.new do
          begin
            clone.execute(loop_spec, timeout: 600)
          rescue MutationTester::Error, IOError
            nil
          end
        end

        child_pid = nil
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
        loop do
          child_pid = clone.instance_variable_get(:@current_child)
          break if child_pid
          break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          sleep 0.05
        end
        expect(child_pid).not_to be_nil

        clone_pid = worker_pid(clone)
        described_class.shutdown_all
        thread.join(5)

        expect(dead_within?(clone_pid, 5)).to be(true)
        expect(dead_within?(child_pid, 5)).to be(true)
      end
    end
  end
end
