require 'json'
require 'tempfile'
require 'tmpdir'
require 'fileutils'

module MutationTester
  class ForkRunner
    InMemoryOutcome = Struct.new(:status, :message)

    WORKER_PATH = File.expand_path('fork_runner/worker.rb', __dir__)
    IN_MEMORY_POOL_KEY = :in_memory
    BOOT_TIMEOUT = 60
    CLONE_TIMEOUT = 10
    RESPONSE_GRACE = 15
    SHUTDOWN_GRACE = 2
    POLL_INTERVAL = 0.05
    HANDSHAKE_POLL = 0.005

    class << self
      def available?
        Process.respond_to?(:fork)
      end

      def acquire(use_bundle_exec:, framework: :rspec)
        return nil unless available?

        key = [Process.pid, use_bundle_exec, framework]
        return registry[key] if registry.key?(key)

        registry[key] = checkout_pooled(pool_key(use_bundle_exec, framework)) || boot(use_bundle_exec, framework)
      end

      def prepare_pool(count, use_bundle_exec:, framework: :rspec, env_for: nil)
        return unless available?

        primary = acquire(use_bundle_exec: use_bundle_exec, framework: framework)
        return unless primary

        refill_pool(pool_key(use_bundle_exec, framework), count, primary, env_for: env_for)
      end

      def prepare_in_memory_pool(count, primary, env_for: nil, after_fork: nil)
        return [] unless available? && primary&.ready?

        refill_pool(IN_MEMORY_POOL_KEY, count, primary, env_for: env_for, after_fork: after_fork)
      end

      def in_memory_pool_prepared?
        pool.key?(IN_MEMORY_POOL_KEY)
      end

      def checkout_in_memory
        number = parallel_worker_number
        return nil unless number

        entry = pool[IN_MEMORY_POOL_KEY]
        entry && entry[:runners][number]
      end

      def shutdown_in_memory_pool
        entry = pool[IN_MEMORY_POOL_KEY]
        return unless entry && entry[:owner] == Process.pid

        pool.delete(IN_MEMORY_POOL_KEY)
        entry[:runners].compact.map { |runner| Thread.new { runner.shutdown } }.each(&:join)
      end

      def shutdown_all
        owned = pool.each_value.select { |entry| entry[:owner] == Process.pid }
        owned.flat_map { |entry| entry[:runners] }.compact
             .map { |runner| Thread.new { runner.shutdown } }
             .each(&:join)
        pool.delete_if { |_, entry| entry[:owner] == Process.pid }
        registry.each do |(pid, _), runner|
          runner&.shutdown if pid == Process.pid
        end
        registry.delete_if { |(pid, _), _| pid == Process.pid }
      end

      def discard(runner)
        registry.delete_if { |_, value| value.equal?(runner) }
        pool.each_value do |entry|
          entry[:runners].map! { |value| value.equal?(runner) ? nil : value }
        end
      end

      def registry
        @registry ||= {}
      end

      def pool
        @pool ||= {}
      end

      def attached(pid, job_writer, event_reader)
        runner = allocate
        runner.send(:attach_endpoints, pid, job_writer, event_reader, CLONE_TIMEOUT, tolerate_eof: true)
        runner
      end

      private

      def pool_key(use_bundle_exec, framework)
        [use_bundle_exec, framework]
      end

      def checkout_pooled(key)
        number = parallel_worker_number
        return nil unless number

        entry = pool[key]
        entry && entry[:runners][number]
      end

      def parallel_worker_number
        Parallel.worker_number if defined?(Parallel) && Parallel.respond_to?(:worker_number)
      end

      def refill_pool(key, count, primary, env_for: nil, after_fork: nil)
        entry = (pool[key] ||= { owner: Process.pid, runners: [] })
        entry[:runners] = entry[:runners].each_with_index.map do |runner, index|
          runner&.ready? ? runner : primary.fork_clone(env: env_for&.call(index), after_fork: after_fork)
        end
        entry[:runners].size.upto(count - 1) do |index|
          entry[:runners] << primary.fork_clone(env: env_for&.call(index), after_fork: after_fork)
        end
        entry[:runners]
      end

      def boot(use_bundle_exec, framework)
        runner = new(use_bundle_exec: use_bundle_exec, framework: framework)
        return runner if runner.ready?

        runner.shutdown
        warn '[MutationTester] The fork runner worker failed to preload the environment; falling back to spawn execution.'
        nil
      end
    end

    def initialize(use_bundle_exec:, framework: :rspec)
      argv = ['ruby', WORKER_PATH, framework.to_s]
      argv = ['bundle', 'exec', *argv] if use_bundle_exec

      job_reader, job_writer = IO.pipe
      event_reader, event_writer = IO.pipe
      pid = Process.spawn(*argv, pgroup: true, in: job_reader, out: event_writer, err: File::NULL)
      job_reader.close
      event_writer.close
      attach_endpoints(pid, job_writer, event_reader, BOOT_TIMEOUT)
    end

    def ready?
      @ready
    end

    def execute(spec_file, timeout: nil, chdir: nil, capture: false, args: [], stop_on_first_failure: false,
                mirror_of: nil)
      log = capture ? Tempfile.new(['mutation_tester_fork', '.log']) : nil
      job = {
        spec: spec_file,
        timeout: timeout,
        chdir: chdir,
        log: log&.path,
        args: args,
        stop_on_first_failure: stop_on_first_failure,
        mirror_of: mirror_of
      }
      @job_writer.puts(JSON.generate(job))
      status = await_result(timeout)['status']
      result = TestCommand::Result.new(status == 'pass', status == 'timeout')
      result.output = File.read(log.path) if log
      result
    rescue Errno::EPIPE
      fail_worker
    ensure
      log&.close
      log&.unlink
    end

    def preload(spec_file, chdir: nil, stop_on_first_failure: false)
      request = { spec: spec_file, chdir: chdir, stop_on_first_failure: stop_on_first_failure }
      @job_writer.puts(JSON.generate(preload: request))
      event = read_event(monotonic_time + BOOT_TIMEOUT)
      return [true, nil] if event.is_a?(Hash) && event['event'] == 'preloaded' && event['status'] == 'ok'

      message = event.is_a?(Hash) && event['message'] ? event['message'] : 'the worker did not confirm the spec preload'
      [false, message]
    rescue Errno::EPIPE, IOError
      [false, 'the fork runner worker terminated unexpectedly']
    end

    def execute_in_memory(source:, path:, timeout: nil, chdir: nil)
      job = { in_memory: { source: source, path: path }, timeout: timeout, chdir: chdir }
      @job_writer.puts(JSON.generate(job))
      event = await_result(timeout)
      InMemoryOutcome.new(event['status'], event['message'])
    rescue Errno::EPIPE
      fail_worker
    end

    def fork_clone(env: nil, after_fork: nil)
      return nil unless ready?
      return nil unless File.respond_to?(:mkfifo)

      dir = Dir.mktmpdir('mutation_tester_clone')
      job_path = File.join(dir, 'job')
      events_path = File.join(dir, 'events')
      File.mkfifo(job_path)
      File.mkfifo(events_path)

      clone_request = { 'job' => job_path, 'events' => events_path }
      clone_request['env'] = env if env
      clone_request['after_fork'] = after_fork if after_fork
      @job_writer.puts(JSON.generate('clone' => clone_request))
      event = read_event(monotonic_time + CLONE_TIMEOUT)
      return nil unless event.is_a?(Hash) && event['event'] == 'cloned'

      adopt_clone(event['pid'], job_path, events_path)
    rescue SystemCallError, IOError
      nil
    ensure
      FileUtils.remove_entry(dir) if dir
    end

    def shutdown
      @shutdown_mutex.synchronize do
        pid = @pid
        next unless pid

        @pid = nil
        kill_group(@current_child) if @current_child
        @current_child = nil
        begin
          Process.kill('TERM', pid)
        rescue Errno::ESRCH
        end
        kill_group(pid) unless reaped_within(pid, SHUTDOWN_GRACE)
        close_pipes
        @ready = false
      end
    end

    private

    def attach_endpoints(pid, job_writer, event_reader, ready_timeout, tolerate_eof: false)
      @pid = pid
      @job_writer = job_writer
      @job_writer.sync = true
      @event_reader = event_reader
      @current_child = nil
      @shutdown_mutex = Mutex.new
      @ready = await_ready(monotonic_time + ready_timeout, tolerate_eof)
    end

    def await_ready(deadline, tolerate_eof)
      loop do
        event = read_event(deadline)
        return false if event == :deadline

        if event.nil?
          return false unless tolerate_eof && process_alive?(@pid)
          return false if monotonic_time >= deadline

          sleep(HANDSHAKE_POLL)
          next
        end

        if event['event'] == 'clone_error'
          warn("[MutationTester] #{event['message']}")
          return false
        end

        return event['event'] == 'ready'
      end
    end

    def adopt_clone(pid, job_path, events_path)
      event_reader = File.open(events_path, File::RDONLY | File::NONBLOCK)
      job_writer = open_fifo_writer(job_path, monotonic_time + CLONE_TIMEOUT)

      unless job_writer
        event_reader.close
        kill_group(pid)
        return nil
      end

      clone = self.class.attached(pid, job_writer, event_reader)
      return clone if clone.ready?

      clone.shutdown
      nil
    end

    def open_fifo_writer(path, deadline)
      loop do
        return File.open(path, File::WRONLY | File::NONBLOCK)
      rescue Errno::ENXIO
        return nil if monotonic_time >= deadline

        sleep(HANDSHAKE_POLL)
      end
    end

    def await_result(timeout)
      deadline = timeout ? monotonic_time + timeout + RESPONSE_GRACE : nil

      loop do
        event = read_event(deadline)
        return handle_wedged_worker if event == :deadline

        fail_worker if event.nil?

        case event['event']
        when 'started'
          @current_child = event['pid']
        when 'result'
          @current_child = nil
          return event
        end
      end
    end

    def handle_wedged_worker
      shutdown
      self.class.discard(self)
      { 'status' => 'timeout' }
    end

    def fail_worker
      shutdown
      self.class.discard(self)
      raise MutationTester::Error, 'The fork runner worker terminated unexpectedly'
    end

    def read_event(deadline)
      loop do
        wait = deadline ? deadline - monotonic_time : nil
        return :deadline if wait && wait <= 0

        ready = IO.select([@event_reader], nil, nil, wait)
        next unless ready

        line = @event_reader.gets
        return nil if line.nil?

        return JSON.parse(line)
      end
    rescue JSON::ParserError
      nil
    end

    def reaped_within(pid, grace)
      deadline = monotonic_time + grace
      loop do
        return true if Process.waitpid(pid, Process::WNOHANG)
        return false if monotonic_time >= deadline

        sleep(POLL_INTERVAL)
      end
    rescue Errno::ECHILD, Errno::ESRCH
      vanished_within(pid, deadline)
    end

    def vanished_within(pid, deadline)
      loop do
        return true unless process_alive?(pid)
        return false if monotonic_time >= deadline

        sleep(HANDSHAKE_POLL)
      end
    end

    def process_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def kill_group(pid)
      Process.kill('KILL', -pid)
    rescue Errno::ESRCH, Errno::EPERM
    ensure
      begin
        Process.waitpid(pid)
      rescue Errno::ECHILD, Errno::ESRCH
      end
    end

    def close_pipes
      [@job_writer, @event_reader].each do |io|
        io.close unless io.nil? || io.closed?
      end
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
