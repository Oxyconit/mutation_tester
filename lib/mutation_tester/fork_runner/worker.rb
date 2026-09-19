# frozen_string_literal: true

require 'json'
require_relative '../in_memory_loader'

control = $stdout.dup
control.sync = true
STDOUT.reopen(File::NULL)

framework = ARGV.shift == 'minitest' ? :minitest : :rspec

if framework == :minitest
  require_relative '../minitest_fail_fast'
  require_relative '../test_recorder/minitest_hook'
  MutationTester::MinitestLoadHook.on_load { Minitest.class_variable_set(:@@installed_at_exit, true) }
else
  require 'rspec/core'
  require_relative '../test_recorder/rspec_hook'
end

kill_group = lambda do |pid|
  begin
    Process.kill('KILL', -pid)
  rescue Errno::ESRCH, Errno::EPERM
  end
end

monotonic = lambda { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

resolved_path = lambda do |path|
  File.realpath(path)
rescue SystemCallError
  path
end

mirror_load_path = lambda do |from, to|
  next if from.nil? || to.nil? || from == to

  roots = [from, resolved_path.call(from)].uniq.map { |root| root.chomp('/') }
  $LOAD_PATH.map! do |entry|
    path = File.expand_path(entry.to_s, from)
    root = roots.find { |candidate| path == candidate || path.start_with?("#{candidate}/") }
    next entry unless root

    suffix = path.delete_prefix(root).delete_prefix('/')
    suffix.empty? ? to : File.join(to, suffix)
  end
end

current_child = nil
preloaded = nil

%w[TERM INT].each do |signal|
  trap(signal) do
    kill_group.call(current_child) if current_child
    trap(signal, 'DEFAULT')
    Process.kill(signal, Process.pid)
  end
end

supervise_child = lambda do |job, out, child_body|
  result_reader, result_writer = IO.pipe

  child = fork do
    trap('TERM', 'DEFAULT')
    trap('INT', 'DEFAULT')
    out.close
    result_reader.close
    begin
      Process.setpgid(0, 0)
    rescue Errno::EACCES, Errno::EPERM
    end
    Dir.chdir(job['chdir']) if job['chdir']
    job['env']&.each { |name, value| ENV[name] = value }
    mirror_load_path.call(job['mirror_of'], job['chdir'])
    sink = File.open(job['log'] || File::NULL, 'w')
    sink.sync = true
    STDOUT.reopen(sink)
    STDERR.reopen(sink)
    result_writer.puts(child_body.call)
    result_writer.close
  end

  result_writer.close
  begin
    Process.setpgid(child, child)
  rescue Errno::EACCES, Errno::EPERM, Errno::ESRCH
  end
  current_child = child
  out.puts(JSON.generate('event' => 'started', 'pid' => child))

  deadline = job['timeout'] ? monotonic.call + job['timeout'] : nil
  reaped = nil
  timed_out = false
  payload_ready = false

  loop do
    _pid, reaped = Process.waitpid2(child, Process::WNOHANG)
    break if reaped

    if deadline && monotonic.call >= deadline
      timed_out = true
      kill_group.call(child)
      begin
        Process.waitpid(child)
      rescue Errno::ECHILD
      end
      break
    end

    if payload_ready
      sleep(0.002)
    else
      remaining = deadline ? deadline - monotonic.call : nil
      wait = remaining ? remaining.clamp(0, 0.05) : 0.05
      payload_ready = !IO.select([result_reader], nil, nil, wait).nil?
    end
  end

  current_child = nil
  payload = result_reader.read
  result_reader.close
  [timed_out, payload, reaped]
end

load_test_file = lambda do |path|
  $PROGRAM_NAME = path
  load(path)
end

run_test_file = lambda do |job|
  if framework == :minitest
    MutationTester::MinitestFailFast.enabled = job['stop_on_first_failure'] ? true : false
    load_test_file.call(job['spec'])
    Minitest.run(Array(job['args'])) ? 0 : 1
  else
    args = [job['spec'], *Array(job['args'])]
    args << '--fail-fast' if job['stop_on_first_failure']
    RSpec::Core::Runner.run(args, STDERR, STDOUT).to_i
  end
end

run_job = lambda do |job, out|
  timed_out, payload, reaped = supervise_child.call(job, out, lambda { run_test_file.call(job) })

  status =
    if timed_out
      'timeout'
    elsif payload[/-?\d+/] == '0' && reaped.success?
      'pass'
    else
      'fail'
    end

  out.puts(JSON.generate('event' => 'result', 'status' => status))
end

preload_specs = lambda do |request, out|
  begin
    Dir.chdir(request['chdir']) if request['chdir']
    if framework == :minitest
      MutationTester::MinitestFailFast.enabled = request['stop_on_first_failure'] ? true : false
      load_test_file.call(request['spec'])
      preloaded = true
    else
      sink = File.open(File::NULL, 'w')
      options = [request['spec']]
      options << '--fail-fast' if request['stop_on_first_failure']
      runner = RSpec::Core::Runner.new(RSpec::Core::ConfigurationOptions.new(options))
      runner.setup(sink, sink)
      preloaded = runner
    end
    out.puts(JSON.generate('event' => 'preloaded', 'status' => 'ok'))
  rescue ScriptError, StandardError => e
    out.puts(JSON.generate('event' => 'preloaded', 'status' => 'error', 'message' => "#{e.class}: #{e.message}"))
  end
end

run_preloaded_suite = lambda do
  if framework == :minitest
    Minitest.run([]) ? 0 : 1
  else
    preloaded.run_specs(RSpec.world.ordered_example_groups).to_i
  end
end

run_in_memory_job = lambda do |job, out|
  request = job['in_memory']

  unless preloaded
    out.puts(JSON.generate('event' => 'result', 'status' => 'error', 'message' => 'the worker has no preloaded spec environment'))
    next
  end

  timed_out, payload, reaped = supervise_child.call(job, out, lambda do
    begin
      MutationTester::InMemoryLoader.apply(request['source'], request['path'])
      JSON.generate('code' => run_preloaded_suite.call)
    rescue ScriptError, StandardError => e
      JSON.generate('error' => "#{e.class}: #{e.message}")
    end
  end)

  outcome = begin
    JSON.parse(payload)
  rescue JSON::ParserError
    nil
  end

  event =
    if timed_out
      { 'event' => 'result', 'status' => 'timeout' }
    elsif outcome.is_a?(Hash) && outcome['error']
      { 'event' => 'result', 'status' => 'error', 'message' => outcome['error'] }
    elsif outcome.is_a?(Hash) && outcome['code'] == 0 && reaped.success?
      { 'event' => 'result', 'status' => 'pass' }
    else
      { 'event' => 'result', 'status' => 'fail' }
    end

  out.puts(JSON.generate(event))
end

serve = nil

spawn_clone = lambda do |request, out|
  child = fork do
    guard = Thread.new do
      sleep 15
      Process.kill('KILL', Process.pid)
    end
    begin
      Process.setpgid(0, 0)
    rescue Errno::EACCES, Errno::EPERM
    end
    input = File.open(request['job'], 'r')
    clone_out = File.open(request['events'], 'w')
    guard.kill
    clone_out.sync = true
    out.close
    STDIN.reopen(File::NULL)
    request['env']&.each { |name, value| ENV[name] = value }
    if request['after_fork']
      begin
        load(request['after_fork'])
      rescue ScriptError, StandardError => e
        clone_out.puts(JSON.generate(
          'event' => 'clone_error',
          'message' => "the after-fork file #{request['after_fork']} raised #{e.class}: #{e.message}; this clone is unavailable"
        ))
        raise
      end
    end
    serve.call(input, clone_out)
  end
  Process.detach(child)
  out.puts(JSON.generate('event' => 'cloned', 'pid' => child))
end

serve = lambda do |input, out|
  out.puts(JSON.generate('event' => 'ready'))
  input.each_line do |line|
    job = JSON.parse(line)
    if job['clone']
      spawn_clone.call(job['clone'], out)
    elsif job['preload']
      preload_specs.call(job['preload'], out)
    elsif job['in_memory']
      run_in_memory_job.call(job, out)
    else
      run_job.call(job, out)
    end
  end
end

serve.call($stdin, control)
