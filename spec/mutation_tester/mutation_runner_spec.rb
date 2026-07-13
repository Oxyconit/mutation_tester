require 'spec_helper'
require 'tmpdir'
require 'stringio'

RSpec.describe MutationTester::MutationRunner do
  let(:config) { MutationTester::Configuration.new }
  let(:runner) { described_class.new('lib/foo.rb', 'spec/foo_spec.rb', 'content', config) }

  describe '#find_project_root' do
    let(:tmp_dir) { Dir.mktmpdir }

    after { FileUtils.remove_entry(tmp_dir) }

    it 'finds root with Gemfile' do
      FileUtils.touch(File.join(tmp_dir, 'Gemfile'))
      lib_dir = File.join(tmp_dir, 'lib')
      FileUtils.mkdir_p(lib_dir)

      runner.instance_variable_set(:@source_file, File.join(lib_dir, 'foo.rb'))

      expect(runner.find_project_root).to eq(tmp_dir)
    end

    it 'finds root with .git' do
      FileUtils.mkdir_p(File.join(tmp_dir, '.git'))
      lib_dir = File.join(tmp_dir, 'lib')
      FileUtils.mkdir_p(lib_dir)

      runner.instance_variable_set(:@source_file, File.join(lib_dir, 'foo.rb'))

      expect(runner.find_project_root).to eq(tmp_dir)
    end

    it 'raises error if no root found (safety check)' do
      deep_dir = File.join(tmp_dir, 'a', 'b', 'c')
      FileUtils.mkdir_p(deep_dir)

      runner.instance_variable_set(:@source_file, File.join(deep_dir, 'foo.rb'))

      expect { runner.find_project_root }.to raise_error(MutationTester::Error, /Could not find project root/)
    end
  end

  describe '#run parallel progress reporting' do
    let(:config) do
      cfg = MutationTester::Configuration.new
      cfg.parallel_processes = 2
      cfg.runner = :spawn
      cfg
    end
    let(:runner) { described_class.new('lib/foo.rb', 'spec/foo_spec.rb', 'content', config) }
    let(:mutations) { (1..6).map { |i| { id: i, type: :arithmetic, line: i } } }

    before do
      allow(runner).to receive(:run_single_mutation) do |mutation, strategy, _project_root|
        { id: mutation[:id], strategy: strategy, worker_pid: Process.pid }
      end
      allow(runner).to receive(:find_project_root).and_return(Dir.pwd)
    end

    it 'invokes progress_callback in the parent process with an increasing 1..N counter' do
      parent_pid = Process.pid
      callback_pids = []
      counts = []

      results = runner.run(mutations) do |_mutation, index|
        callback_pids << Process.pid
        counts << index
      end

      expect(results.map { |r| r[:id] }).to eq((1..6).to_a)
      expect(results.map { |r| r[:worker_pid] }).to all(satisfy { |pid| pid != parent_pid })

      expect(callback_pids).not_to be_empty
      expect(callback_pids).to all(eq(parent_pid))
      expect(counts).to eq(counts.sort)
      expect(counts).to all(be_between(1, mutations.size))
      expect(counts.last).to eq(mutations.size)
    end

    it 'reports intermediate counter values during the run' do
      counts = []
      runner.run(mutations) { |_mutation, index| counts << index }

      expect(counts).to eq([2, 4, 6])
      expect(counts.any? { |c| c.positive? && c < mutations.size }).to be(true)
    end
  end

  describe '#run_in_place_series fail-fast early termination' do
    let(:tmp_dir) { Dir.mktmpdir }
    let(:source_file) { File.join(tmp_dir, 'calc.rb') }
    let(:spec_file) { File.join(tmp_dir, 'calc_spec.rb') }
    let(:original_content) { "x = 1\n" }
    let(:mutations) { (1..3).map { |i| { id: i, code: "x = #{i + 1}\n" } } }

    before { File.write(source_file, original_content) }
    after { FileUtils.remove_entry(tmp_dir) }

    def build_runner(fail_fast)
      cfg = MutationTester::Configuration.new
      cfg.fail_fast = fail_fast
      described_class.new(source_file, spec_file, original_content, cfg)
    end

    def stub_first_mutant_survives(runner)
      allow(runner).to receive(:run_single_mutation) do |mutation, _strategy|
        status = mutation[:id] == 1 ? :survived : :killed
        { id: mutation[:id], status: status }
      end
    end

    it 'stops after the first surviving mutant when fail_fast is enabled' do
      runner = build_runner(true)
      stub_first_mutant_survives(runner)

      results = runner.run_in_place_series(mutations)

      expect(runner).to have_received(:run_single_mutation).once
      expect(results.size).to eq(1)
      expect(results.first).to include(id: 1, status: :survived)
    end

    it 'runs every mutation when fail_fast is disabled even though a mutant survives' do
      runner = build_runner(false)
      stub_first_mutant_survives(runner)

      results = runner.run_in_place_series(mutations)

      expect(runner).to have_received(:run_single_mutation).exactly(3).times
      expect(results.map { |r| r[:id] }).to eq([1, 2, 3])
    end
  end

  describe '#shadow_copy_project' do
    it 'raises error if source is system directory' do
      expect { runner.shadow_copy_project('/', '/tmp/dest') }.to raise_error(MutationTester::Error, /Refusing to shadow copy/)
      expect { runner.shadow_copy_project('/usr', '/tmp/dest') }.to raise_error(MutationTester::Error, /Refusing to shadow copy/)
    end

    it 'copies .rb files as regular files and leaves non-.rb files as symlinks' do
      Dir.mktmpdir do |tmp|
        source = File.join(tmp, 'proj')
        dest = File.join(tmp, 'shadow')
        FileUtils.mkdir_p(File.join(source, 'lib'))
        FileUtils.mkdir_p(dest)

        File.write(File.join(source, 'lib', 'thing.rb'), "class Thing; end\n")
        File.write(File.join(source, 'config.yml'), "foo: bar\n")
        File.write(File.join(source, 'README.md'), "# hi\n")

        runner.shadow_copy_project(source, dest)

        shadow_rb = File.join(dest, 'lib', 'thing.rb')
        shadow_yml = File.join(dest, 'config.yml')
        shadow_md = File.join(dest, 'README.md')

        expect(File.symlink?(shadow_rb)).to be(false)
        expect(File.file?(shadow_rb)).to be(true)
        expect(File.read(shadow_rb)).to eq("class Thing; end\n")
        expect(File.realpath(shadow_rb)).to start_with(File.realpath(dest))

        expect(File.symlink?(shadow_yml)).to be(true)
        expect(File.symlink?(shadow_md)).to be(true)
      end
    end

    it 'excludes .git, tmp, log, coverage and node_modules from the shadow' do
      Dir.mktmpdir do |tmp|
        source = File.join(tmp, 'proj')
        dest = File.join(tmp, 'shadow')
        %w[.git tmp log coverage node_modules lib].each { |d| FileUtils.mkdir_p(File.join(source, d)) }
        File.write(File.join(source, 'node_modules', 'pkg.rb'), "x = 1\n")
        File.write(File.join(source, 'lib', 'thing.rb'), "class Thing; end\n")
        FileUtils.mkdir_p(dest)

        runner.shadow_copy_project(source, dest)

        %w[.git tmp log coverage node_modules].each do |excluded|
          expect(File.exist?(File.join(dest, excluded))).to be(false)
        end
        expect(File.file?(File.join(dest, 'lib', 'thing.rb'))).to be(true)
      end
    end
  end

  describe '#shadow_baseline_passes?' do
    let(:tmp_dir) { Dir.mktmpdir }
    let(:project_root) { File.join(tmp_dir, 'proj') }
    let(:source_file) { File.join(project_root, 'lib', 'calc.rb') }
    let(:spec_file) { File.join(project_root, 'spec', 'calc_spec.rb') }
    let(:original_source) { "class Calc\n  def add(a, b)\n    a + b\n  end\nend\n" }
    let(:config) { MutationTester::Configuration.new }

    before do
      FileUtils.mkdir_p(File.join(project_root, '.git'))
      FileUtils.mkdir_p(File.dirname(source_file))
      FileUtils.mkdir_p(File.dirname(spec_file))
      File.write(source_file, original_source)
    end

    after { FileUtils.remove_entry(tmp_dir) }

    def build_runner
      described_class.new(source_file, spec_file, File.read(source_file), config)
    end

    it 'returns true when the unmutated source passes in the shadow workspace' do
      File.write(spec_file, <<~RUBY)
        require_relative '../lib/calc'

        RSpec.describe Calc do
          it('adds') { expect(Calc.new.add(1, 2)).to eq(3) }
        end
      RUBY

      expect(build_runner.shadow_baseline_passes?).to be(true)
    end

    it 'returns false when the pristine suite fails only in shadow (excluded-dir dependency)' do
      FileUtils.mkdir_p(File.join(project_root, 'tmp'))
      File.write(File.join(project_root, 'tmp', 'helper.rb'), "SHADOW_HELPER_OK = true\n")
      File.write(spec_file, <<~RUBY)
        require_relative '../lib/calc'
        require_relative '../tmp/helper'

        RSpec.describe Calc do
          it('adds') { expect(SHADOW_HELPER_OK && Calc.new.add(1, 2) == 3).to be(true) }
        end
      RUBY

      original_passes = Dir.chdir(project_root) do
        MutationTester::TestCommand.new(spec_file, use_bundle_exec: false)
                                   .run(timeout: config.timeout).passed?
      end
      expect(original_passes).to be(true)

      expect(build_runner.shadow_baseline_passes?).to be(false)
    end

    it 'returns false without propagating when preparing the shadow raises (copy failure)' do
      File.write(spec_file, <<~RUBY)
        require_relative '../lib/calc'

        RSpec.describe Calc do
          it('adds') { expect(Calc.new.add(1, 2)).to eq(3) }
        end
      RUBY

      runner = build_runner
      allow(runner).to receive(:shadow_copy_project)
        .and_raise(MutationTester::Error, 'boom copying shadow')

      result = nil
      expect { result = runner.shadow_baseline_passes? }.not_to raise_error
      expect(result).to be(false)
    end

    it 'returns false without propagating when find_project_root raises' do
      runner = build_runner
      allow(runner).to receive(:find_project_root)
        .and_raise(MutationTester::Error, 'Could not find project root')

      result = nil
      expect { result = runner.shadow_baseline_passes? }.not_to raise_error
      expect(result).to be(false)
    end
  end

  describe '#detect_test_framework' do
    it 'detects minitest by filename' do
      expect(runner.detect_test_framework('foo_test.rb')).to eq(:minitest)
      expect(runner.detect_test_framework('test_foo.rb')).to eq(:minitest)
    end

    it 'detects rspec by filename' do
      expect(runner.detect_test_framework('foo_spec.rb')).to eq(:rspec)
    end

    it 'detects by content if filename ambiguous' do
      allow(File).to receive(:exist?).and_return(true)
      allow(File).to receive(:read).and_return("require 'minitest'")
      expect(runner.detect_test_framework('foo.rb')).to eq(:minitest)
    end
  end

  describe 'hard mutant timeout without the external `timeout` binary' do
    let(:tmp_dir) { Dir.mktmpdir }
    let(:project_root) { File.join(tmp_dir, 'proj') }
    let(:config) do
      cfg = MutationTester::Configuration.new
      cfg.timeout = 2
      cfg.runner = :spawn
      cfg
    end
    let(:infinite_loop_code) { "while true; end\n" }

    after { FileUtils.remove_entry(tmp_dir) }

    around do |example|
      original_path = ENV['PATH']
      ENV['PATH'] = original_path
        .split(File::PATH_SEPARATOR)
        .reject { |dir| File.executable?(File.join(dir, 'timeout')) }
        .join(File::PATH_SEPARATOR)
      example.run
    ensure
      ENV['PATH'] = original_path
    end

    def process_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    end

    def track_spawned_pids
      pids = []
      allow(Process).to receive(:spawn).and_wrap_original do |original, *args|
        pid = original.call(*args)
        pids << pid
        pid
      end
      pids
    end

    def build_project(framework)
      FileUtils.mkdir_p(File.join(project_root, 'lib'))
      FileUtils.mkdir_p(File.join(project_root, '.git'))
      source = File.join(project_root, 'lib', 'calc.rb')
      File.write(source, "class Calc\n  def add(a, b)\n    a + b\n  end\nend\n")

      if framework == :minitest
        FileUtils.mkdir_p(File.join(project_root, 'test'))
        spec = File.join(project_root, 'test', 'calc_test.rb')
        File.write(spec, <<~RUBY)
          require 'minitest/autorun'
          require_relative '../lib/calc'

          class CalcTest < Minitest::Test
            def test_add
              assert_equal 3, Calc.new.add(1, 2)
            end
          end
        RUBY
      else
        FileUtils.mkdir_p(File.join(project_root, 'spec'))
        spec = File.join(project_root, 'spec', 'calc_spec.rb')
        File.write(spec, <<~RUBY)
          require_relative '../lib/calc'

          RSpec.describe Calc do
            it 'adds two numbers' do
              expect(Calc.new.add(1, 2)).to eq(3)
            end
          end
        RUBY
      end

      source
    end

    def run_infinite_loop_mutation(source, spec, strategy)
      runner = described_class.new(source, spec, File.read(source), config)
      mutation = {
        id: 1,
        type: :infinite,
        line: 1,
        code: infinite_loop_code,
        description: 'infinite loop'
      }

      if strategy == :in_place
        Dir.chdir(project_root) { runner.run_single_mutation(mutation, :in_place) }
      else
        begin
          runner.run_single_mutation(mutation, :shadow, project_root)
        ensure
          runner.cleanup_shadow_workspaces
        end
      end
    end

    %i[rspec minitest].each do |framework|
      %i[in_place shadow].each do |strategy|
        context "#{framework} / #{strategy}" do
          let(:spec_file) do
            source = build_project(framework)
            @source = source
            framework == :minitest ? File.join(project_root, 'test', 'calc_test.rb')
                                   : File.join(project_root, 'spec', 'calc_spec.rb')
          end

          it 'kills the infinite-loop mutant as a timeout within the deadline and leaves no orphan' do
            spec = spec_file
            pids = track_spawned_pids

            started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            result = run_infinite_loop_mutation(@source, spec, strategy)
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

            expect(result[:timeout]).to be(true)
            expect(result[:killed]).to be(true)
            expect(elapsed).to be < (config.timeout + 5)

            expect(pids).not_to be_empty
            pids.each { |pid| expect(process_alive?(pid)).to be(false) }
          end
        end
      end
    end
  end

  describe 'natural completion under an active deadline is never a false timeout' do
    let(:tmp_dir) { Dir.mktmpdir }
    let(:project_root) { File.join(tmp_dir, 'proj') }
    let(:source_file) { File.join(project_root, 'lib', 'calc.rb') }
    let(:spec_file) { File.join(project_root, 'spec', 'calc_spec.rb') }
    let(:original_source) do
      <<~RUBY
        class Calc
          def add(a, b)
            a + b
          end

          def unused(a)
            a + 1
          end
        end
      RUBY
    end
    let(:config) do
      cfg = MutationTester::Configuration.new
      cfg.timeout = 30
      cfg.runner = :spawn
      cfg
    end

    def process_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    end

    def track_spawned_pids
      pids = []
      allow(Process).to receive(:spawn).and_wrap_original do |original, *args|
        pid = original.call(*args)
        pids << pid
        pid
      end
      pids
    end

    before do
      FileUtils.mkdir_p(File.dirname(source_file))
      FileUtils.mkdir_p(File.dirname(spec_file))
      File.write(source_file, original_source)
      File.write(spec_file, <<~RUBY)
        require_relative '../lib/calc'

        RSpec.describe Calc do
          it 'adds two numbers' do
            expect(Calc.new.add(1, 2)).to eq(3)
          end
        end
      RUBY
    end

    after { FileUtils.remove_entry(tmp_dir) }

    def run_mutant(code, line)
      runner = described_class.new(source_file, spec_file, original_source, config)
      mutation = { id: 1, type: :arithmetic, line: line, code: code, description: 'd' }
      Dir.chdir(project_root) { runner.run_single_mutation(mutation, :in_place) }
    end

    it 'reports a covered mutant that finishes on its own as killed, not timeout' do
      pids = track_spawned_pids
      result = run_mutant(<<~RUBY, 3)
        class Calc
          def add(a, b)
            a - b
          end

          def unused(a)
            a + 1
          end
        end
      RUBY

      expect(result[:status]).to eq(:killed)
      expect(result[:timeout]).to be(false)
      expect(pids).not_to be_empty
      pids.each { |pid| expect(process_alive?(pid)).to be(false) }
    end

    it 'reports an uncovered mutant that finishes on its own as survived, not timeout' do
      pids = track_spawned_pids
      result = run_mutant(<<~RUBY, 7)
        class Calc
          def add(a, b)
            a + b
          end

          def unused(a)
            a - 1
          end
        end
      RUBY

      expect(result[:status]).to eq(:survived)
      expect(result[:timeout]).to be(false)
      expect(pids).not_to be_empty
      pids.each { |pid| expect(process_alive?(pid)).to be(false) }
    end
  end

  describe 'fork execution parity with spawn' do
    let(:tmp_dir) { Dir.mktmpdir }
    let(:project_root) { File.join(tmp_dir, 'proj') }
    let(:source_file) { File.join(project_root, 'lib', 'calc.rb') }
    let(:spec_file) { File.join(project_root, 'spec', 'calc_spec.rb') }
    let(:original_source) do
      <<~RUBY
        class Calc
          def add(a, b)
            a + b
          end

          def unused(a)
            a + 1
          end
        end
      RUBY
    end

    before do
      FileUtils.mkdir_p(File.join(project_root, '.git'))
      FileUtils.mkdir_p(File.dirname(source_file))
      FileUtils.mkdir_p(File.dirname(spec_file))
      File.write(source_file, original_source)
      File.write(spec_file, <<~RUBY)
        require_relative '../lib/calc'

        RSpec.describe Calc do
          it('adds') { expect(Calc.new.add(1, 2)).to eq(3) }
        end
      RUBY
    end

    after do
      MutationTester::ForkRunner.shutdown_all
      FileUtils.remove_entry(tmp_dir)
    end

    def mutations
      [
        { id: 1, type: :arithmetic, line: 3, description: 'covered',
          code: original_source.sub('a + b', 'a - b') },
        { id: 2, type: :arithmetic, line: 7, description: 'uncovered',
          code: original_source.sub('a + 1', 'a - 1') },
        { id: 3, type: :arithmetic, line: 1, description: 'stillborn',
          code: 'def broken(; end' }
      ]
    end

    def run_with(runner_mode, timeout: 30)
      config = MutationTester::Configuration.new
      config.runner = runner_mode
      config.parallel_processes = 1
      config.timeout = timeout
      runner = described_class.new(source_file, spec_file, original_source, config)
      Dir.chdir(project_root) { runner.run(mutations) }
    end

    it 'reports identical per-mutant statuses for spawn and fork execution' do
      spawn_results = run_with(:spawn)
      fork_results = run_with(:fork)

      expect(fork_results.map { |r| r[:status] }).to eq(spawn_results.map { |r| r[:status] })
      expect(fork_results.map { |r| r[:status] }).to eq(%i[killed survived stillborn])
      expect(File.read(source_file)).to eq(original_source)
    end

    it 'kills an infinite-loop mutant in fork mode as a hard timeout within the deadline' do
      config = MutationTester::Configuration.new
      config.runner = :fork
      config.timeout = 2
      runner = described_class.new(source_file, spec_file, original_source, config)
      mutation = { id: 1, type: :infinite, line: 1, code: "while true; end\n", description: 'loop' }

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = Dir.chdir(project_root) { runner.run_single_mutation(mutation, :in_place) }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(result[:status]).to eq(:timeout)
      expect(result[:killed]).to be(true)
      expect(elapsed).to be < (config.timeout + 7)
    end
  end

  describe 'in-memory execution' do
    let(:tmp_dir) { Dir.mktmpdir }
    let(:project_root) { File.join(tmp_dir, 'proj') }
    let(:source_file) { File.join(project_root, 'lib', 'calc.rb') }
    let(:spec_file) { File.join(project_root, 'spec', 'calc_spec.rb') }
    let(:original_source) do
      <<~RUBY
        class Calc
          LIMIT = 5

          def add(a, b)
            a + b
          end

          def unused(a)
            a + 1
          end

          def capped?(value)
            value >= LIMIT
          end
        end
      RUBY
    end
    let(:spec_source) do
      <<~RUBY
        require_relative '../lib/calc'

        RSpec.describe Calc do
          it('adds') { expect(Calc.new.add(1, 2)).to eq(3) }
          it('caps at the limit') { expect(Calc.new.capped?(5)).to be(true) }
          it('does not cap below the limit') { expect(Calc.new.capped?(4)).to be(false) }
        end
      RUBY
    end

    before do
      FileUtils.mkdir_p(File.join(project_root, '.git'))
      FileUtils.mkdir_p(File.dirname(source_file))
      FileUtils.mkdir_p(File.dirname(spec_file))
      File.write(source_file, original_source)
      File.write(spec_file, spec_source)
    end

    after do
      MutationTester::ForkRunner.shutdown_all
      FileUtils.remove_entry(tmp_dir)
    end

    def mutations
      [
        { id: 1, type: :arithmetic, line: 5, description: 'covered',
          code: original_source.sub('a + b', 'a - b') },
        { id: 2, type: :number, line: 2, description: 'constant boundary',
          code: original_source.sub('LIMIT = 5', 'LIMIT = 4') },
        { id: 3, type: :arithmetic, line: 9, description: 'uncovered',
          code: original_source.sub('a + 1', 'a - 1') },
        { id: 4, type: :arithmetic, line: 1, description: 'stillborn',
          code: 'def broken(; end' }
      ]
    end

    def build_runner(runner_mode, processes: 1, source: original_source)
      config = MutationTester::Configuration.new
      config.runner = runner_mode
      config.parallel_processes = processes
      config.timeout = 30
      described_class.new(source_file, spec_file, source, config)
    end

    def run_with(runner_mode, muts: mutations, processes: 1, &callback)
      runner = build_runner(runner_mode, processes: processes)
      Dir.chdir(project_root) { runner.run(muts, &callback) }
    end

    it 'reports the same per-mutant statuses as fork execution, including the class constant mutant' do
      fork_results = run_with(:fork)
      in_memory_results = run_with(:in_memory)

      expect(in_memory_results.map { |r| r[:status] }).to eq(fork_results.map { |r| r[:status] })
      expect(in_memory_results.map { |r| r[:status] }).to eq(%i[killed killed survived stillborn])
      expect(in_memory_results.none? { |r| r.key?(:kill_phase) }).to be(true)
    end

    it 'leaves the source file and the project directory untouched for the whole run' do
      written_paths = []
      allow(File).to receive(:write).and_wrap_original do |original, path, *args|
        written_paths << File.expand_path(path.to_s)
        original.call(path, *args)
      end
      mtime_before = File.mtime(source_file)
      entries_before = Dir.glob(File.join(project_root, '**', '*'), File::FNM_DOTMATCH).sort

      runner = build_runner(:in_memory)
      seen_during_run = []
      results = Dir.chdir(project_root) do
        runner.run(mutations) do |_mutation, _index|
          seen_during_run << [
            File.read(source_file) == original_source,
            File.mtime(source_file) == mtime_before,
            File.exist?("#{source_file}.mutation_backup")
          ]
        end
      end

      expect(results.map { |r| r[:status] }).to eq(%i[killed killed survived stillborn])
      expect(seen_during_run.size).to eq(mutations.size)
      expect(seen_during_run).to all(eq([true, true, false]))
      expect(File.mtime(source_file)).to eq(mtime_before)
      expect(Dir.glob(File.join(project_root, '**', '*'), File::FNM_DOTMATCH).sort).to eq(entries_before)
      expect(written_paths.select { |path| path.start_with?(project_root) }).to be_empty
      expect(runner.instance_variable_get(:@shadow_run_root)).to be_nil
    end

    it 'decides a mutant whose in-memory application raises through the file-based fallback, killing an unloadable mutant' do
      raising = [
        mutations[0],
        { id: 5, type: :arithmetic, line: 1, description: 'raises at load',
          code: "class Calc\n  raise 'top level boom'\nend\n" },
        mutations[2]
      ]

      runner = build_runner(:in_memory)
      results = nil
      expect { results = Dir.chdir(project_root) { runner.run(raising) } }
        .to output(/could not be applied in memory.*top level boom.*file-based/m).to_stderr

      expect(results.map { |r| r[:status] }).to eq(%i[killed killed survived])
      expect(runner.instance_variable_get(:@shadow_run_root)).to be_nil
    end

    it 'applies a mutant containing require_relative identically to fork execution' do
      FileUtils.mkdir_p(File.join(project_root, 'lib'))
      File.write(File.join(project_root, 'lib', 'calc_helper.rb'), "CALC_HELPER_LOADED = true\n")
      source = <<~RUBY
        require_relative 'calc_helper'

        class Calc
          def add(a, b)
            a + b
          end
        end
      RUBY
      File.write(source_file, source)
      File.write(spec_file, <<~RUBY)
        require_relative '../lib/calc'

        RSpec.describe Calc do
          it('adds') { expect(CALC_HELPER_LOADED && Calc.new.add(1, 2) == 3).to be(true) }
        end
      RUBY
      muts = [
        { id: 1, type: :arithmetic, line: 5, description: 'covered', code: source.sub('a + b', 'a - b') },
        { id: 2, type: :arithmetic, line: 5, description: 'equivalent', code: source.sub('a + b', 'b + a') }
      ]

      fork_results = Dir.chdir(project_root) { described_class.new(source_file, spec_file, source, build_config(:fork)).run(muts) }
      in_memory_results = Dir.chdir(project_root) { described_class.new(source_file, spec_file, source, build_config(:in_memory)).run(muts) }

      expect(in_memory_results.map { |r| r[:status] }).to eq(fork_results.map { |r| r[:status] })
      expect(in_memory_results.map { |r| r[:status] }).to eq(%i[killed survived])
    end

    def build_config(runner_mode)
      config = MutationTester::Configuration.new
      config.runner = runner_mode
      config.parallel_processes = 1
      config.timeout = 30
      config
    end

    it 'falls back to file-based execution with a message when the source has a load-time defined? guard' do
      source = original_source.sub('LIMIT = 5', 'LIMIT = 5 unless defined?(Calc::LIMIT)')
      File.write(source_file, source)
      runner = build_runner(:in_memory, source: source)
      muts = [{ id: 1, type: :arithmetic, line: 5, description: 'covered', code: source.sub('a + b', 'a - b') }]

      results = nil
      expect { results = Dir.chdir(project_root) { runner.run(muts) } }
        .to output(/In-memory execution is unavailable: .*defined\?.*Falling back to file-based execution/m).to_stderr

      expect(results.map { |r| r[:status] }).to eq([:killed])
      expect(File.read(source_file)).to eq(source)
    end

    it 'falls back with a message when re-applying the unmutated source in memory breaks the suite' do
      source = <<~RUBY
        $calc_load_count = $calc_load_count.to_i + 1

        class Calc
          def add(a, b)
            a + b
          end
        end
      RUBY
      File.write(source_file, source)
      File.write(spec_file, <<~RUBY)
        require_relative '../lib/calc'

        RSpec.describe Calc do
          it('loads the file exactly once') { expect($calc_load_count).to eq(1) }
          it('adds') { expect(Calc.new.add(1, 2)).to eq(3) }
        end
      RUBY
      runner = build_runner(:in_memory, source: source)
      muts = [{ id: 1, type: :arithmetic, line: 5, description: 'covered', code: source.sub('a + b', 'a - b') }]

      results = nil
      expect { results = Dir.chdir(project_root) { runner.run(muts) } }
        .to output(/In-memory execution is unavailable: .*unmutated source.*Falling back to file-based execution/m).to_stderr

      expect(results.map { |r| r[:status] }).to eq([:killed])
    end

    it 'falls back with a message when the class is frozen and cannot be redefined in memory' do
      source = original_source + "Calc.freeze\n"
      File.write(source_file, source)
      runner = build_runner(:in_memory, source: source)
      muts = [{ id: 1, type: :arithmetic, line: 5, description: 'covered', code: source.sub('a + b', 'a - b') }]

      results = nil
      expect { results = Dir.chdir(project_root) { runner.run(muts) } }
        .to output(/In-memory execution is unavailable: .*Falling back to file-based execution/m).to_stderr

      expect(results.map { |r| r[:status] }).to eq([:killed])
    end

    it 'falls back with a message for minitest suites' do
      test_file = File.join(project_root, 'test', 'calc_test.rb')
      FileUtils.mkdir_p(File.dirname(test_file))
      File.write(test_file, <<~RUBY)
        require 'minitest/autorun'
        require_relative '../lib/calc'

        class CalcTest < Minitest::Test
          def test_add
            assert_equal 3, Calc.new.add(1, 2)
          end
        end
      RUBY
      config = build_config(:in_memory)
      runner = described_class.new(source_file, test_file, original_source, config)
      muts = [mutations[0], mutations[2]]

      results = nil
      expect { results = Dir.chdir(project_root) { runner.run(muts) } }
        .to output(/In-memory execution is unavailable: .*RSpec.*Falling back to file-based execution/m).to_stderr

      expect(results.map { |r| r[:status] }).to eq(%i[killed survived])
    end

    it 'runs mutations in parallel through a pool of clones forked from the spec-preloaded worker' do
      expect(MutationTester::ForkRunner).to receive(:prepare_in_memory_pool)
        .with(3, kind_of(MutationTester::ForkRunner)).and_call_original
      expect(Parallel).to receive(:map)
        .with(anything, hash_including(in_processes: 3)).and_call_original

      results = run_with(:in_memory, processes: 3)

      expect(results.map { |r| r[:status] }).to eq(%i[killed killed survived stillborn])
      expect(results.none? { |r| r.key?(:kill_phase) }).to be(true)
    end

    it 'reports the same per-mutant statuses in parallel as the serial fork run' do
      fork_results = run_with(:fork)
      parallel_results = run_with(:in_memory, processes: 2)

      expect(parallel_results.map { |r| r[:status] }).to eq(fork_results.map { |r| r[:status] })
      expect(parallel_results.map { |r| r[:status] }).to eq(%i[killed killed survived stillborn])
    end

    it 'leaves the project untouched and never materializes a shadow workspace during a parallel run' do
      mtime_before = File.mtime(source_file)
      entries_before = Dir.glob(File.join(project_root, '**', '*'), File::FNM_DOTMATCH).sort

      runner = build_runner(:in_memory, processes: 2)
      seen_during_run = []
      results = Dir.chdir(project_root) do
        runner.run(mutations) do |_mutation, _index|
          shadow_root = runner.instance_variable_get(:@shadow_run_root)
          seen_during_run << [
            File.read(source_file) == original_source,
            File.exist?("#{source_file}.mutation_backup"),
            shadow_root ? File.directory?(shadow_root) : false
          ]
        end
      end

      expect(results.map { |r| r[:status] }).to eq(%i[killed killed survived stillborn])
      expect(seen_during_run).not_to be_empty
      expect(seen_during_run).to all(eq([true, false, false]))
      expect(File.mtime(source_file)).to eq(mtime_before)
      expect(Dir.glob(File.join(project_root, '**', '*'), File::FNM_DOTMATCH).sort).to eq(entries_before)
    end

    it 'falls back to the parallel file-based path with a message when a whole-run blocker is present' do
      source = original_source.sub('LIMIT = 5', 'LIMIT = 5 unless defined?(Calc::LIMIT)')
      File.write(source_file, source)
      runner = build_runner(:in_memory, processes: 2, source: source)
      muts = [
        { id: 1, type: :arithmetic, line: 5, description: 'covered', code: source.sub('a + b', 'a - b') },
        { id: 2, type: :arithmetic, line: 9, description: 'uncovered', code: source.sub('a + 1', 'a - 1') }
      ]

      results = nil
      expect { results = Dir.chdir(project_root) { runner.run(muts) } }
        .to output(/In-memory execution is unavailable: .*defined\?.*Falling back to file-based execution/m).to_stderr

      expect(results.map { |r| r[:status] }).to eq(%i[killed survived])
      expect(File.read(source_file)).to eq(source)
    end

    it 'finishes the remaining mutants file-based with correct progress when an in-memory worker dies mid-run' do
      runner = build_runner(:in_memory, processes: 2)
      clone_killed = false
      allow(runner).to receive(:run_single_mutation).and_wrap_original do |original, *args|
        unless clone_killed
          clone_killed = true
          clone = MutationTester::ForkRunner.checkout_in_memory
          Process.kill('KILL', clone.instance_variable_get(:@pid)) if clone
        end
        original.call(*args)
      end

      counts = []
      results = nil
      expect do
        results = Dir.chdir(project_root) { runner.run(mutations) { |_mutation, index| counts << index } }
      end.to output(/finishing its share of mutants file-based/).to_stderr_from_any_process

      expect(results.map { |r| r[:status] }).to eq(%i[killed killed survived stillborn])
      expect(counts).to eq([2, 4])
      expect(File.read(source_file)).to eq(original_source)
    end

    it 'finishes the remaining mutants through the fallback when the worker dies mid-run' do
      workers = []
      allow(MutationTester::ForkRunner).to receive(:new).and_wrap_original do |original, **kwargs|
        workers << original.call(**kwargs)
        workers.last
      end

      runner = build_runner(:in_memory)
      first_done = false
      allow(runner).to receive(:run_single_mutation).and_wrap_original do |original, *args|
        result = original.call(*args)
        unless first_done
          first_done = true
          workers.first.shutdown
        end
        result
      end

      results = nil
      expect { results = Dir.chdir(project_root) { runner.run(mutations) } }
        .to output(/terminated unexpectedly.*Falling back to file-based execution/m).to_stderr

      expect(results.map { |r| r[:status] }).to eq(%i[killed killed survived stillborn])
      expect(File.read(source_file)).to eq(original_source)
    end

    it 'reports increasing progress across the in-memory run and its mid-run fallback' do
      workers = []
      allow(MutationTester::ForkRunner).to receive(:new).and_wrap_original do |original, **kwargs|
        workers << original.call(**kwargs)
        workers.last
      end

      runner = build_runner(:in_memory)
      first_done = false
      allow(runner).to receive(:run_single_mutation).and_wrap_original do |original, *args|
        result = original.call(*args)
        unless first_done
          first_done = true
          workers.first.shutdown
        end
        result
      end

      counts = []
      expect do
        Dir.chdir(project_root) { runner.run(mutations) { |_mutation, index| counts << index } }
      end.to output(/Falling back to file-based execution/).to_stderr

      expect(counts).to eq([1, 2, 3, 4])
    end

    it 'runs mutants in memory by default, booting the preloaded worker exactly once' do
      expect(MutationTester::ForkRunner).to receive(:new).once.and_call_original
      expect(Parallel).not_to receive(:map)

      results = run_with(:auto)

      expect(results.map { |r| r[:status] }).to eq(%i[killed killed survived stillborn])
      expect(results.none? { |r| r.key?(:kill_phase) }).to be(true)
    end

    it 'runs the default parallel path through the in-memory clone pool without a second full boot' do
      expect(MutationTester::ForkRunner).to receive(:new).once.and_call_original
      expect(MutationTester::ForkRunner).to receive(:prepare_in_memory_pool)
        .with(2, kind_of(MutationTester::ForkRunner)).and_call_original

      results = run_with(:auto, processes: 2)

      expect(results.map { |r| r[:status] }).to eq(%i[killed killed survived stillborn])
    end

    it 'announces the fork landing mode when the default runner steps down to file-based execution' do
      source = original_source.sub('LIMIT = 5', 'LIMIT = 5 unless defined?(Calc::LIMIT)')
      File.write(source_file, source)
      runner = build_runner(:auto, source: source)
      muts = [{ id: 1, type: :arithmetic, line: 5, description: 'covered', code: source.sub('a + b', 'a - b') }]

      results = nil
      expect { results = Dir.chdir(project_root) { runner.run(muts) } }
        .to output(/In-memory execution is unavailable: .*defined\?.*Falling back to file-based execution \(fork\)\./m).to_stderr

      expect(results.map { |r| r[:status] }).to eq([:killed])
    end

    it 'steps a minitest suite down to spawn with an explicit reason and without booting any worker' do
      test_file = File.join(project_root, 'test', 'calc_test.rb')
      FileUtils.mkdir_p(File.dirname(test_file))
      File.write(test_file, <<~RUBY)
        require 'minitest/autorun'
        require_relative '../lib/calc'

        class CalcTest < Minitest::Test
          def test_add
            assert_equal 3, Calc.new.add(1, 2)
          end
        end
      RUBY
      expect(MutationTester::ForkRunner).not_to receive(:new)
      config = build_config(:auto)
      runner = described_class.new(source_file, test_file, original_source, config)
      muts = [mutations[0], mutations[2]]

      results = nil
      expect { results = Dir.chdir(project_root) { runner.run(muts) } }
        .to output(/In-memory execution is unavailable: .*RSpec.*Falling back to file-based execution \(spawn\)\./m).to_stderr

      expect(results.map { |r| r[:status] }).to eq(%i[killed survived])
    end

    it 'never probes the in-memory path when a file-based runner is forced' do
      %i[fork spawn].each do |mode|
        runner = build_runner(mode)
        expect(runner).not_to receive(:prepare_in_memory_execution)

        results = Dir.chdir(project_root) { runner.run([mutations[0]]) }

        expect(results.map { |r| r[:status] }).to eq([:killed])
      end
    end
  end

  describe 'parallel execution with a shared preloaded worker pool' do
    let(:tmp_dir) { Dir.mktmpdir }
    let(:project_root) { File.join(tmp_dir, 'proj') }
    let(:source_file) { File.join(project_root, 'lib', 'calc.rb') }
    let(:spec_file) { File.join(project_root, 'spec', 'calc_spec.rb') }
    let(:original_source) do
      <<~RUBY
        class Calc
          def add(a, b)
            a + b
          end

          def unused(a)
            a + 1
          end
        end
      RUBY
    end

    before do
      FileUtils.mkdir_p(File.join(project_root, '.git'))
      FileUtils.mkdir_p(File.dirname(source_file))
      FileUtils.mkdir_p(File.dirname(spec_file))
      File.write(source_file, original_source)
      File.write(spec_file, <<~RUBY)
        require_relative '../lib/calc'

        RSpec.describe Calc do
          describe '#add' do
            it('adds') { expect(Calc.new.add(1, 2)).to eq(3) }
          end
        end
      RUBY
    end

    after do
      MutationTester::ForkRunner.shutdown_all
      FileUtils.remove_entry(tmp_dir)
    end

    def mutations
      [
        { id: 1, type: :arithmetic, line: 3, method_name: 'add', description: 'covered',
          code: original_source.sub('a + b', 'a - b') },
        { id: 2, type: :arithmetic, line: 7, method_name: 'unused', description: 'uncovered',
          code: original_source.sub('a + 1', 'a - 1') },
        { id: 3, type: :arithmetic, line: 1, method_name: 'add', description: 'stillborn',
          code: 'def broken(; end' }
      ]
    end

    def run_with(processes:, selection: true, muts: mutations, timeout: 30)
      config = MutationTester::Configuration.new
      config.parallel_processes = processes
      config.runner = :fork
      config.timeout = timeout
      config.test_selection = selection
      runner = described_class.new(source_file, spec_file, original_source, config)
      Dir.chdir(project_root) { runner.run(muts) }
    end

    it 'prepares one shared preload pool in the parent before the workers start' do
      run_with(processes: 2)

      entry = MutationTester::ForkRunner.pool[false]
      expect(entry).not_to be_nil
      expect(entry[:owner]).to eq(Process.pid)
      expect(entry[:runners].compact.size).to eq(2)
    end

    it 'reports the same statuses as the serial run and tags subset kills visibly for the parent' do
      parallel_results = run_with(processes: 2)
      serial_results = run_with(processes: 1)

      expect(parallel_results.map { |r| r[:status] }).to eq(serial_results.map { |r| r[:status] })
      expect(parallel_results.map { |r| r[:status] }).to eq(%i[killed survived stillborn])
      expect(parallel_results.first[:kill_phase]).to eq(:subset)
      expect(serial_results.first[:kill_phase]).to eq(:subset)
      expect(parallel_results[1]).not_to have_key(:kill_phase)
      expect(File.read(source_file)).to eq(original_source)
    end

    it 'runs the full file for every mutant when test selection is disabled' do
      results = run_with(processes: 2, selection: false)

      expect(results.map { |r| r[:status] }).to eq(%i[killed survived stillborn])
      expect(results.first[:kill_phase]).to eq(:full)
    end

    it 'kills an infinite-loop mutant within the deadline in parallel mode' do
      looping = [{ id: 1, type: :infinite, line: 1, code: "while true; end\n", description: 'loop' }]

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      results = run_with(processes: 2, muts: looping, timeout: 2)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(results.map { |r| r[:status] }).to eq([:timeout])
      expect(results.first[:killed]).to be(true)
      expect(elapsed).to be < 15
    end
  end

  describe 'result status taxonomy' do
    let(:tmp_dir) { Dir.mktmpdir }
    let(:source) { File.join(tmp_dir, 'foo.rb') }
    let(:spec) { File.join(tmp_dir, 'foo_spec.rb') }
    let(:original_content) { "x = 1\n" }
    let(:config) { MutationTester::Configuration.new }
    let(:runner) { described_class.new(source, spec, original_content, config) }

    before { File.write(source, original_content) }
    after { FileUtils.remove_entry(tmp_dir) }

    def outcome(passed, timed_out)
      MutationTester::TestCommand::Result.new(passed, timed_out)
    end

    it 'marks an unparseable mutant stillborn without running the tests' do
      unparseable = described_class.new('lib/foo.rb', 'spec/foo_spec.rb', 'x = 1', config)
      expect(unparseable).not_to receive(:run_mutation_in_place)

      result = unparseable.run_single_mutation(
        { id: 1, type: :arithmetic, line: 1, code: 'def broken(; end', description: 'broken' },
        :in_place
      )

      expect(result[:status]).to eq(:stillborn)
      expect(result[:killed]).to be(false)
      expect(result[:timeout]).to be(false)
    end

    it 'classifies a timed-out run as timeout and counts it as killed' do
      allow(runner).to receive(:run_specs_in_place).and_return(outcome(false, true))

      result = runner.run_single_mutation(
        { id: 1, type: :arithmetic, line: 1, code: "x = 2\n", description: 'd' },
        :in_place
      )

      expect(result[:status]).to eq(:timeout)
      expect(result[:killed]).to be(true)
      expect(result[:timeout]).to be(true)
    end

    it 'classifies a non-zero exit as killed' do
      allow(runner).to receive(:run_specs_in_place).and_return(outcome(false, false))

      result = runner.run_single_mutation(
        { id: 1, type: :arithmetic, line: 1, code: "x = 2\n", description: 'd' },
        :in_place
      )

      expect(result[:status]).to eq(:killed)
      expect(result[:killed]).to be(true)
      expect(result[:timeout]).to be(false)
    end

    it 'classifies a clean exit as survived' do
      allow(runner).to receive(:run_specs_in_place).and_return(outcome(true, false))

      result = runner.run_single_mutation(
        { id: 1, type: :arithmetic, line: 1, code: "x = 2\n", description: 'd' },
        :in_place
      )

      expect(result[:status]).to eq(:survived)
      expect(result[:killed]).to be(false)
    end

    it 'marks a write failure as error with the message, not survived' do
      allow(File).to receive(:write).and_wrap_original do |orig, path, content|
        raise IOError, 'disk full' if content == "x = 2\n"

        orig.call(path, content)
      end

      result = runner.run_single_mutation(
        { id: 1, type: :arithmetic, line: 1, code: "x = 2\n", description: 'd' },
        :in_place
      )

      expect(result[:status]).to eq(:error)
      expect(result[:status]).not_to eq(:survived)
      expect(result[:killed]).to be(false)
      expect(result[:description]).to include('disk full')
      expect(File.read(source)).to eq(original_content)
    end
  end

  describe 'spec path with spaces and shell metacharacters' do
    let(:tmp_dir) { Dir.mktmpdir }
    let(:project_root) { File.join(tmp_dir, 'proj') }
    let(:source_file) { File.join(project_root, 'lib', 'calc.rb') }
    let(:spec_file) { File.join(project_root, 'spec', 'a b;c_spec.rb') }
    let(:original_source) do
      <<~RUBY
        class Calc
          def add(a, b)
            a + b
          end

          def unused(a)
            a + 1
          end
        end
      RUBY
    end
    let(:config) { MutationTester::Configuration.new }

    before do
      FileUtils.mkdir_p(File.dirname(source_file))
      FileUtils.mkdir_p(File.dirname(spec_file))
      File.write(source_file, original_source)
      File.write(spec_file, <<~RUBY)
        require_relative '../lib/calc'

        RSpec.describe Calc do
          it 'adds two numbers' do
            expect(Calc.new.add(1, 2)).to eq(3)
          end
        end
      RUBY
    end

    after { FileUtils.remove_entry(tmp_dir) }

    def run_mutant(code, line)
      runner = described_class.new(source_file, spec_file, original_source, config)
      mutation = { id: 1, type: :arithmetic, line: line, code: code, description: 'd' }
      Dir.chdir(project_root) { runner.run_single_mutation(mutation, :in_place) }
    end

    it 'kills a covered mutant at the metacharacter path (tests actually ran)' do
      killed = run_mutant(<<~RUBY, 3)
        class Calc
          def add(a, b)
            a - b
          end

          def unused(a)
            a + 1
          end
        end
      RUBY

      expect(killed[:status]).to eq(:killed)
      expect(killed[:killed]).to be(true)
    end

    it 'reports an uncovered mutant at the metacharacter path as survived' do
      survived = run_mutant(<<~RUBY, 7)
        class Calc
          def add(a, b)
            a + b
          end

          def unused(a)
            a - 1
          end
        end
      RUBY

      expect(survived[:status]).to eq(:survived)
      expect(survived[:killed]).to be(false)
    end
  end

  describe 'no dependency on the external `timeout` binary' do
    let(:tmp_dir) { Dir.mktmpdir }
    let(:project_root) { File.join(tmp_dir, 'proj') }
    let(:config) do
      cfg = MutationTester::Configuration.new
      cfg.timeout = 2
      cfg.runner = :spawn
      cfg
    end

    after { FileUtils.remove_entry(tmp_dir) }

    it 'no longer probes for the timeout binary per mutation' do
      expect(described_class.private_instance_methods).not_to include(:timeout_available?)
      expect(described_class.instance_methods).not_to include(:run_timeout)
    end

    it 'spawns the bare framework command with no `timeout` wrapper' do
      FileUtils.mkdir_p(File.join(project_root, 'lib'))
      FileUtils.mkdir_p(File.join(project_root, 'spec'))
      source = File.join(project_root, 'lib', 'calc.rb')
      spec = File.join(project_root, 'spec', 'calc_spec.rb')
      File.write(source, "class Calc\n  def add(a, b)\n    a + b\n  end\nend\n")
      File.write(spec, <<~RUBY)
        require_relative '../lib/calc'

        RSpec.describe Calc do
          it 'adds two numbers' do
            expect(Calc.new.add(1, 2)).to eq(3)
          end
        end
      RUBY

      commands = []
      allow(Process).to receive(:spawn).and_wrap_original do |original, *args|
        commands << args.first
        original.call(*args)
      end

      runner = described_class.new(source, spec, File.read(source), config)
      mutation = {
        id: 1,
        type: :arithmetic,
        line: 3,
        code: "class Calc\n  def add(a, b)\n    a - b\n  end\nend\n",
        description: 'a + b -> a - b'
      }
      Dir.chdir(project_root) { runner.run_single_mutation(mutation, :in_place) }

      expect(commands).not_to be_empty
      commands.each { |cmd| expect(cmd).not_to match(/\btimeout\b/) }
    end
  end

  describe 'in-place SIGKILL resilience: on-disk backup and recovery' do
    let(:tmp_dir) { Dir.mktmpdir }
    let(:project_root) { File.join(tmp_dir, 'proj') }
    let(:source_file) { File.join(project_root, 'lib', 'calc.rb') }
    let(:spec_file) { File.join(project_root, 'spec', 'calc_spec.rb') }
    let(:original_source) { "class Calc\n  def add(a, b)\n    a + b\n  end\nend\n" }
    let(:mutated_source) { "class Calc\n  def add(a, b)\n    a - b\n  end\nend\n" }
    let(:backup) { "#{source_file}.mutation_backup" }
    let(:config) do
      cfg = MutationTester::Configuration.new
      cfg.runner = :spawn
      cfg.parallel_processes = 1
      cfg
    end
    let(:runner) { described_class.new(source_file, spec_file, original_source, config) }

    before do
      FileUtils.mkdir_p(File.dirname(source_file))
      FileUtils.mkdir_p(File.dirname(spec_file))
      File.write(source_file, original_source)
      File.write(spec_file, <<~RUBY)
        require_relative '../lib/calc'

        RSpec.describe Calc do
          it('adds') { expect(Calc.new.add(1, 2)).to eq(3) }
        end
      RUBY
    end

    after { FileUtils.remove_entry(tmp_dir) }

    it 'writes the on-disk backup before the series and keeps it during the run' do
      seen_during_run = []
      allow(runner).to receive(:run_single_mutation) do |mutation, _strategy|
        seen_during_run << File.exist?(backup)
        { id: mutation[:id], status: :survived }
      end

      runner.run([{ id: 1, code: original_source }, { id: 2, code: original_source }])

      expect(seen_during_run).to eq([true, true])
      expect(File.exist?(backup)).to be(false)
    end

    it 'backs up the pristine original content, not a mutated file' do
      captured = nil
      allow(runner).to receive(:run_single_mutation) do |mutation, _strategy|
        captured = File.read(backup)
        { id: mutation[:id], status: :survived }
      end

      runner.run([{ id: 1, code: original_source }])

      expect(captured).to eq(original_source)
    end

    it 'removes the backup and leaves the source byte-identical after a clean run' do
      mutation = { id: 1, type: :arithmetic, line: 3, code: mutated_source, description: 'a + b -> a - b' }

      results = Dir.chdir(project_root) { runner.run([mutation]) }

      expect(results.first[:status]).to eq(:killed)
      expect(File.exist?(backup)).to be(false)
      expect(File.read(source_file)).to eq(original_source)
    end

    it 'restores from the backup even when a mutant leaves the source mutated' do
      allow(runner).to receive(:run_single_mutation) do |mutation, _strategy|
        File.write(source_file, mutated_source)
        { id: mutation[:id], status: :survived }
      end

      runner.run([{ id: 1, code: original_source }])

      expect(File.read(source_file)).to eq(original_source)
      expect(File.exist?(backup)).to be(false)
    end

    describe '.recover_in_place_backup' do
      it 'restores the source from a leftover backup and deletes the backup' do
        File.write(source_file, mutated_source)
        File.write(backup, original_source)

        expect(described_class.recover_in_place_backup(source_file)).to be(true)

        expect(File.read(source_file)).to eq(original_source)
        expect(File.exist?(backup)).to be(false)
      end

      it 'is a no-op returning false when there is no backup' do
        expect(File.exist?(backup)).to be(false)

        expect(described_class.recover_in_place_backup(source_file)).to be(false)

        expect(File.read(source_file)).to eq(original_source)
      end
    end

    describe 'backup neither disturbs generation/detection nor is committed' do
      it 'uses a deterministic <source>.mutation_backup path with a non-source extension' do
        path = described_class.backup_path_for(source_file)

        expect(path).to eq("#{File.expand_path(source_file)}.mutation_backup")
        expect(File.extname(path)).to eq('.mutation_backup')
        expect(File.extname(path)).not_to eq('.rb')
        expect(MutationTester::FrameworkDetector.detect(path)).to eq(:rspec)
      end

      it 'is ignored by the repository .gitignore' do
        repo_root = File.expand_path('../..', __dir__)
        ignored = Dir.chdir(repo_root) do
          system('git', 'check-ignore', '-q', 'examples/calculator.rb.mutation_backup')
        end

        expect(ignored).to be(true)
      end
    end
  end

  describe '#run_mutation_in_place interrupted mid-run' do
    let(:tmp_dir) { Dir.mktmpdir }
    let(:source_file) { File.join(tmp_dir, 'calc.rb') }
    let(:spec_file) { File.join(tmp_dir, 'calc_spec.rb') }
    let(:original_content) { "class Calc\n  def add(a, b)\n    a + b\n  end\nend\n" }
    let(:mutated_content) { "class Calc\n  def add(a, b)\n    a - b\n  end\nend\n" }
    let(:config) { MutationTester::Configuration.new }
    let(:runner) { described_class.new(source_file, spec_file, original_content, config) }

    before { File.write(source_file, original_content) }
    after { FileUtils.remove_entry(tmp_dir) }

    it 'marks the mutant :error, re-raises the Interrupt, and restores the source in ensure' do
      allow(runner).to receive(:run_specs_in_place).and_raise(Interrupt)

      result = { status: :survived, killed: false, timeout: false, description: 'd' }
      mutation = { id: 1, type: :arithmetic, line: 3, code: mutated_content, description: 'a + b -> a - b' }

      expect { runner.run_mutation_in_place(mutation, result) }.to raise_error(Interrupt)

      expect(result[:status]).to eq(:error)
      expect(result[:killed]).to be(false)

      expect(File.read(source_file)).to eq(original_content)
    end
  end

  describe '#run_mutation_in_shadow runner error' do
    let(:tmp_dir) { Dir.mktmpdir }
    let(:project_root) { File.join(tmp_dir, 'proj') }
    let(:source_file) { File.join(project_root, 'lib', 'calc.rb') }
    let(:spec_file) { File.join(project_root, 'spec', 'calc_spec.rb') }
    let(:original_content) { "class Calc\n  def add(a, b)\n    a + b\n  end\nend\n" }
    let(:mutant_code) { "class Calc\n  def add(a, b)\n    a - b\n  end\nend\n" }
    let(:config) { MutationTester::Configuration.new }
    let(:runner) { described_class.new(source_file, spec_file, original_content, config) }

    before do
      FileUtils.mkdir_p(File.join(project_root, '.git'))
      FileUtils.mkdir_p(File.dirname(source_file))
      FileUtils.mkdir_p(File.dirname(spec_file))
      File.write(source_file, original_content)
      File.write(spec_file, <<~RUBY)
        require_relative '../lib/calc'

        RSpec.describe Calc do
          it('adds') { expect(Calc.new.add(1, 2)).to eq(3) }
        end
      RUBY
    end

    after do
      runner.cleanup_shadow_workspaces
      FileUtils.remove_entry(tmp_dir)
    end

    it 'marks the mutant :error with the message without propagating, and keeps it out of the score' do
      allow(File).to receive(:write).and_wrap_original do |orig, path, content|
        raise IOError, 'shadow disk full' if content == mutant_code

        orig.call(path, content)
      end

      mutation = { id: 1, type: :arithmetic, line: 3, code: mutant_code, description: 'a + b -> a - b' }

      result = nil
      expect { result = runner.run_single_mutation(mutation, :shadow, project_root) }.not_to raise_error

      expect(result[:status]).to eq(:error)
      expect(result[:killed]).to be(false)
      expect(result[:description]).to include('shadow disk full')

      combined = [result, { status: :killed, killed: true }, { status: :survived, killed: false }]
      expect(MutationTester::Reporters::BaseReporter.score(combined)).to eq(50.0)
    end
  end

  describe 'persistent shadow workspace per worker' do
    let(:tmp_dir) { Dir.mktmpdir }
    let(:project_root) { File.join(tmp_dir, 'proj') }
    let(:source_file) { File.join(project_root, 'lib', 'calc.rb') }
    let(:spec_file) { File.join(project_root, 'spec', 'calc_spec.rb') }
    let(:original_content) { "class Calc\n  def add(a, b)\n    a + b\n  end\nend\n" }
    let(:config) { MutationTester::Configuration.new }
    let(:runner) { described_class.new(source_file, spec_file, original_content, config) }

    before do
      FileUtils.mkdir_p(File.join(project_root, '.git'))
      FileUtils.mkdir_p(File.dirname(source_file))
      FileUtils.mkdir_p(File.dirname(spec_file))
      File.write(source_file, original_content)
      File.write(spec_file, <<~RUBY)
        require_relative '../lib/calc'

        RSpec.describe Calc do
          it('adds') { expect(Calc.new.add(1, 2)).to eq(3) }
        end
      RUBY
    end

    after do
      runner.cleanup_shadow_workspaces
      FileUtils.remove_entry(tmp_dir)
    end

    def mutant(id)
      {
        id: id, type: :arithmetic, line: 3,
        code: original_content.sub('a + b', "a - b + #{id}"),
        description: 'd'
      }
    end

    def stub_test_runs(passed: false)
      observed = []
      allow(runner).to receive(:run_specs_in_shadow) do |_spec, working_dir, example_filters: []|
        source = File.join(working_dir, 'lib', 'calc.rb')
        observed << { dir: working_dir, source: File.read(source) }
        MutationTester::TestCommand::Result.new(passed, false)
      end
      observed
    end

    it 'copies the project once per worker and reuses the workspace for subsequent mutants' do
      allow(runner).to receive(:shadow_copy_project).and_call_original
      observed = stub_test_runs

      runner.run_single_mutation(mutant(1), :shadow, project_root)
      runner.run_single_mutation(mutant(2), :shadow, project_root)

      expect(runner).to have_received(:shadow_copy_project).with(project_root, anything).once
      expect(observed.map { |o| o[:dir] }.uniq.size).to eq(1)
    end

    it 'runs each mutant against its own mutated source and restores the original afterwards' do
      observed = stub_test_runs

      runner.run_single_mutation(mutant(1), :shadow, project_root)
      runner.run_single_mutation(mutant(2), :shadow, project_root)

      expect(observed.map { |o| o[:source] }).to eq([mutant(1)[:code], mutant(2)[:code]])
      shadow_source = File.join(observed.first[:dir], 'lib', 'calc.rb')
      expect(File.read(shadow_source)).to eq(original_content)
      expect(File.read(source_file)).to eq(original_content)
    end

    it 'marks the mutant :error instead of survived when restoring the workspace source fails' do
      stub_test_runs(passed: true)
      restore_failed = false
      allow(File).to receive(:write).and_wrap_original do |orig, path, content|
        if !restore_failed && content == original_content && path != source_file && path != spec_file
          restore_failed = true
          raise IOError, 'restore failed'
        end

        orig.call(path, content)
      end

      result = runner.run_single_mutation(mutant(1), :shadow, project_root)

      expect(result[:status]).to eq(:error)
      expect(result[:killed]).to be(false)
      expect(result[:description]).to include('restore failed')
    end

    it 'rebuilds a fresh workspace for the next mutant after a failed restore' do
      allow(runner).to receive(:shadow_copy_project).and_call_original
      observed = stub_test_runs
      restore_failed = false
      allow(File).to receive(:write).and_wrap_original do |orig, path, content|
        if !restore_failed && content == original_content && path != source_file && path != spec_file
          restore_failed = true
          raise IOError, 'restore failed'
        end

        orig.call(path, content)
      end

      runner.run_single_mutation(mutant(1), :shadow, project_root)
      result = runner.run_single_mutation(mutant(2), :shadow, project_root)

      expect(runner).to have_received(:shadow_copy_project).with(project_root, anything).twice
      expect(observed.map { |o| o[:dir] }.uniq.size).to eq(2)
      expect(result[:status]).to eq(:killed)
    end
  end

  describe 'shadow run root cleanup' do
    let(:config) do
      cfg = MutationTester::Configuration.new
      cfg.parallel_processes = 2
      cfg.runner = :spawn
      cfg
    end
    let(:runner) { described_class.new('lib/foo.rb', 'spec/foo_spec.rb', 'content', config) }
    let(:mutations) { (1..4).map { |i| { id: i, type: :arithmetic, line: i } } }

    before do
      allow(runner).to receive(:run_single_mutation) do |mutation, strategy, _project_root|
        { id: mutation[:id], strategy: strategy, status: :killed }
      end
      allow(runner).to receive(:find_project_root).and_return(Dir.pwd)
    end

    it 'removes the shadow run root after a completed parallel run' do
      root = runner.send(:shadow_run_root)
      expect(File.directory?(root)).to be(true)

      runner.run(mutations)

      expect(File.exist?(root)).to be(false)
    end

    it 'removes the shadow run root when the parallel run is interrupted' do
      root = runner.send(:shadow_run_root)
      allow(Parallel).to receive(:map).and_raise(Interrupt)

      expect { runner.run(mutations) }.to raise_error(Interrupt)

      expect(File.exist?(root)).to be(false)
    end
  end

  describe 'silencing the parallel gem interrupt line around Parallel.map' do
    let(:mutations) { (1..2).map { |i| { id: i, type: :arithmetic, line: i } } }

    def stub_parallel_map_emitting_gem_line
      allow(Parallel).to receive(:map) do |items, **_opts, &_block|
        warn 'Parallel execution interrupted, exiting ...'
        warn '[MutationTester] a diagnostic that must survive'
        $stdout.write("json document on stdout\n")
        items.map { |mutation| { id: mutation[:id], status: :killed } }
      end
    end

    def run_capturing_std(runner, muts)
      previous_out = $stdout
      previous_err = $stderr
      out = StringIO.new
      err = StringIO.new
      $stdout = out
      $stderr = err
      begin
        results = runner.run(muts)
        stderr_after_run = $stderr
      ensure
        $stdout = previous_out
        $stderr = previous_err
      end
      { results: results, stdout: out.string, stderr: err.string, stderr_after_run: stderr_after_run, err_io: err }
    end

    it 'drops only the gem interrupt line and passes other warns through when emitted via Kernel#warn' do
      config = MutationTester::Configuration.new
      runner = described_class.new('lib/foo.rb', 'spec/foo_spec.rb', 'content', config)

      previous_err = $stderr
      err = StringIO.new
      $stderr = err
      begin
        runner.send(:with_parallel_interrupt_silenced) do
          warn 'Parallel execution interrupted, exiting ...'
          warn '[MutationTester] keep this diagnostic'
        end
        expect($stderr).to equal(err)
      ensure
        $stderr = previous_err
      end

      expect(err.string).not_to include('Parallel execution interrupted')
      expect(err.string).to include('[MutationTester] keep this diagnostic')
    end

    it 'silences the gem line on the file-based parallel path while keeping our stderr and stdout intact' do
      config = MutationTester::Configuration.new
      config.parallel_processes = 2
      config.runner = :spawn
      runner = described_class.new('lib/foo.rb', 'spec/foo_spec.rb', 'content', config)
      allow(runner).to receive(:find_project_root).and_return(Dir.pwd)
      stub_parallel_map_emitting_gem_line

      captured = run_capturing_std(runner, mutations)

      expect(captured[:stderr]).not_to include('Parallel execution interrupted')
      expect(captured[:stderr]).to include('[MutationTester] a diagnostic that must survive')
      expect(captured[:stdout]).to include('json document on stdout')
      expect(captured[:stderr_after_run]).to equal(captured[:err_io])
      expect(captured[:results].map { |r| r[:status] }).to eq(%i[killed killed])
    end

    it 'silences the gem line on the default in-memory parallel path without swallowing diagnostics or stdout' do
      config = MutationTester::Configuration.new
      config.parallel_processes = 2
      config.runner = :in_memory
      runner = described_class.new('lib/foo.rb', 'spec/foo_spec.rb', 'content', config)
      allow(runner).to receive(:prepare_in_memory_execution).and_return(nil)
      allow(runner).to receive(:discoverable_project_root).and_return(Dir.pwd)
      allow(runner).to receive(:shutdown_in_memory_worker)
      allow(MutationTester::ForkRunner).to receive(:prepare_in_memory_pool).and_return(%i[worker_a worker_b])
      allow(MutationTester::ForkRunner).to receive(:shutdown_in_memory_pool)
      stub_parallel_map_emitting_gem_line

      captured = run_capturing_std(runner, mutations)

      expect(captured[:stderr]).not_to include('Parallel execution interrupted')
      expect(captured[:stderr]).to include('[MutationTester] a diagnostic that must survive')
      expect(captured[:stdout]).to include('json document on stdout')
      expect(captured[:stderr_after_run]).to equal(captured[:err_io])
      expect(captured[:results].map { |r| r[:status] }).to eq(%i[killed killed])
    end

    it 'restores $stderr and still cleans up the shadow run root when the parallel map is interrupted' do
      config = MutationTester::Configuration.new
      config.parallel_processes = 2
      config.runner = :spawn
      runner = described_class.new('lib/foo.rb', 'spec/foo_spec.rb', 'content', config)
      allow(runner).to receive(:find_project_root).and_return(Dir.pwd)
      root = runner.send(:shadow_run_root)
      allow(Parallel).to receive(:map).and_raise(Interrupt)

      previous_err = $stderr
      err = StringIO.new
      $stderr = err
      begin
        expect { runner.run(mutations) }.to raise_error(Interrupt)
        expect($stderr).to equal(err)
      ensure
        $stderr = previous_err
      end

      expect(File.exist?(root)).to be(false)
    end
  end

  describe '#shadow_copy_project symlinked directory' do
    it 'recreates a symlinked directory as a symlink instead of copying it recursively' do
      Dir.mktmpdir do |tmp|
        source = File.join(tmp, 'proj')
        dest = File.join(tmp, 'shadow')
        FileUtils.mkdir_p(File.join(source, 'real_dir'))
        File.write(File.join(source, 'real_dir', 'note.txt'), "hi\n")
        external = File.join(tmp, 'external')
        FileUtils.mkdir_p(external)
        File.write(File.join(external, 'ext.txt'), "ext\n")
        File.symlink(external, File.join(source, 'linked_dir'))
        FileUtils.mkdir_p(dest)

        runner.shadow_copy_project(source, dest)

        linked = File.join(dest, 'linked_dir')
        expect(File.symlink?(linked)).to be(true)
        expect(File.directory?(linked)).to be(true)
        expect(File.read(File.join(linked, 'ext.txt'))).to eq("ext\n")
        real = File.join(dest, 'real_dir')
        expect(File.symlink?(real)).to be(false)
        expect(File.directory?(real)).to be(true)
      end
    end

    it 'runs a mutant in shadow when the project contains a symlinked directory' do
      Dir.mktmpdir do |tmp|
        project_root = File.join(tmp, 'proj')
        FileUtils.mkdir_p(File.join(project_root, 'lib'))
        FileUtils.mkdir_p(File.join(project_root, 'spec'))
        FileUtils.mkdir_p(File.join(project_root, '.git'))
        external = File.join(tmp, 'external')
        FileUtils.mkdir_p(external)
        File.write(File.join(external, 'data.txt'), "ok\n")
        File.symlink(external, File.join(project_root, 'linked_dir'))

        source = File.join(project_root, 'lib', 'calc.rb')
        spec = File.join(project_root, 'spec', 'calc_spec.rb')
        File.write(source, "class Calc\n  def add(a, b)\n    a + b\n  end\nend\n")
        File.write(spec, <<~RUBY)
          require_relative '../lib/calc'

          RSpec.describe Calc do
            it('adds') { expect(Calc.new.add(1, 2)).to eq(3) }
          end
        RUBY

        runner = described_class.new(source, spec, File.read(source), config)
        mutation = {
          id: 1, type: :arithmetic, line: 3,
          code: "class Calc\n  def add(a, b)\n    a - b\n  end\nend\n",
          description: 'a + b -> a - b'
        }

        result = begin
          runner.run_single_mutation(mutation, :shadow, project_root)
        ensure
          runner.cleanup_shadow_workspaces
        end

        expect(result[:status]).to eq(:killed)
      end
    end
  end

  describe 'two-phase test selection' do
    let(:tmp_dir) { Dir.mktmpdir }
    let(:source_file) { File.join(tmp_dir, 'lib', 'calc.rb') }
    let(:spec_file) { File.join(tmp_dir, 'spec', 'calc_spec.rb') }
    let(:original_content) { "class Calc\n  def add(a, b)\n    a + b\n  end\nend\n" }
    let(:spec_content) do
      <<~RUBY
        require_relative '../lib/calc'

        RSpec.describe Calc do
          describe '#add' do
            it('adds') { expect(Calc.new.add(1, 2)).to eq(3) }
          end
        end
      RUBY
    end
    let(:config) { MutationTester::Configuration.new }
    let(:runner) { described_class.new(source_file, spec_file, original_content, config) }
    let(:mutation) do
      { id: 1, type: :arithmetic, line: 3, method_name: 'add',
        code: original_content.sub('a + b', 'a - b'), description: 'd' }
    end

    before do
      FileUtils.mkdir_p(File.dirname(source_file))
      FileUtils.mkdir_p(File.dirname(spec_file))
      File.write(source_file, original_content)
      File.write(spec_file, spec_content)
    end

    after { FileUtils.remove_entry(tmp_dir) }

    def outcome(passed, timed_out = false)
      MutationTester::TestCommand::Result.new(passed, timed_out)
    end

    def stub_runs(subset_outcome:, full_outcome:)
      calls = []
      allow(runner).to receive(:run_specs_in_place) do |_spec, example_filters:|
        calls << example_filters
        example_filters.empty? ? full_outcome : subset_outcome
      end
      calls
    end

    it 'runs the matching describe groups first via -e filters' do
      calls = stub_runs(subset_outcome: outcome(false), full_outcome: outcome(true))

      runner.run_single_mutation(mutation, :in_place)

      expect(calls.first).to eq(['#add'])
    end

    it 'reports a failing subset as killed without running the full file' do
      calls = stub_runs(subset_outcome: outcome(false), full_outcome: outcome(true))

      result = runner.run_single_mutation(mutation, :in_place)

      expect(result[:status]).to eq(:killed)
      expect(calls).to eq([['#add']])
    end

    it 'never reports survived from the subset alone: a passing subset with a failing full file is killed' do
      calls = stub_runs(subset_outcome: outcome(true), full_outcome: outcome(false))

      result = runner.run_single_mutation(mutation, :in_place)

      expect(result[:status]).to eq(:killed)
      expect(calls).to eq([['#add'], []])
    end

    it 'reports survived only after the full file also passes' do
      calls = stub_runs(subset_outcome: outcome(true), full_outcome: outcome(true))

      result = runner.run_single_mutation(mutation, :in_place)

      expect(result[:status]).to eq(:survived)
      expect(calls).to eq([['#add'], []])
    end

    it 'classifies a timed-out subset as timeout without running the full file' do
      calls = stub_runs(subset_outcome: outcome(false, true), full_outcome: outcome(true))

      result = runner.run_single_mutation(mutation, :in_place)

      expect(result[:status]).to eq(:timeout)
      expect(result[:killed]).to be(true)
      expect(calls).to eq([['#add']])
    end

    it 'selects both instance and class method groups when the spec describes them' do
      File.write(spec_file, <<~RUBY)
        RSpec.describe Calc do
          describe '#add' do
          end
          describe ".add" do
          end
        end
      RUBY
      calls = stub_runs(subset_outcome: outcome(false), full_outcome: outcome(true))

      runner.run_single_mutation(mutation, :in_place)

      expect(calls.first).to eq(['#add', '.add'])
    end

    it 'runs the full file directly when the mutation has no enclosing method' do
      calls = stub_runs(subset_outcome: outcome(false), full_outcome: outcome(true))

      result = runner.run_single_mutation(mutation.merge(method_name: nil), :in_place)

      expect(result[:status]).to eq(:survived)
      expect(calls).to eq([[]])
    end

    it 'tags a kill from a failing subset with the subset phase' do
      stub_runs(subset_outcome: outcome(false), full_outcome: outcome(true))

      result = runner.run_single_mutation(mutation, :in_place)

      expect(result[:kill_phase]).to eq(:subset)
    end

    it 'tags a timed-out subset with the subset phase' do
      stub_runs(subset_outcome: outcome(false, true), full_outcome: outcome(true))

      result = runner.run_single_mutation(mutation, :in_place)

      expect(result[:kill_phase]).to eq(:subset)
    end

    it 'tags a kill confirmed by the full file with the full phase' do
      stub_runs(subset_outcome: outcome(true), full_outcome: outcome(false))

      result = runner.run_single_mutation(mutation, :in_place)

      expect(result[:kill_phase]).to eq(:full)
    end

    it 'tags a kill as full when no subset was attempted' do
      stub_runs(subset_outcome: outcome(false), full_outcome: outcome(false))

      result = runner.run_single_mutation(mutation.merge(method_name: nil), :in_place)

      expect(result[:kill_phase]).to eq(:full)
    end

    it 'leaves survivors without a kill phase' do
      stub_runs(subset_outcome: outcome(true), full_outcome: outcome(true))

      result = runner.run_single_mutation(mutation, :in_place)

      expect(result).not_to have_key(:kill_phase)
    end

    it 'runs the full file directly when no describe group matches the method' do
      File.write(spec_file, <<~RUBY)
        RSpec.describe Calc do
          it('adds') { expect(Calc.new.add(1, 2)).to eq(3) }
        end
      RUBY
      calls = stub_runs(subset_outcome: outcome(false), full_outcome: outcome(true))

      runner.run_single_mutation(mutation, :in_place)

      expect(calls).to eq([[]])
    end

    it 'runs the full file directly when selection is disabled' do
      config.test_selection = false
      calls = stub_runs(subset_outcome: outcome(false), full_outcome: outcome(true))

      result = runner.run_single_mutation(mutation, :in_place)

      expect(result[:status]).to eq(:survived)
      expect(calls).to eq([[]])
    end

    it 'always runs the full file for minitest' do
      test_file = File.join(tmp_dir, 'test', 'calc_test.rb')
      FileUtils.mkdir_p(File.dirname(test_file))
      File.write(test_file, "class CalcTest\n  def test_add\n  end\nend\n")
      minitest_runner = described_class.new(source_file, test_file, original_content, config)
      calls = []
      allow(minitest_runner).to receive(:run_specs_in_place) do |_spec, example_filters:|
        calls << example_filters
        outcome(true)
      end

      minitest_runner.run_single_mutation(mutation, :in_place)

      expect(calls).to eq([[]])
    end

    it 'applies the same two-phase selection on the shadow path' do
      calls = []
      allow(runner).to receive(:run_specs_in_shadow) do |_spec, _dir, example_filters:|
        calls << example_filters
        example_filters.empty? ? outcome(false) : outcome(true)
      end
      allow(runner).to receive(:shadow_copy_project) do |_source, dest|
        FileUtils.mkdir_p(File.join(dest, 'lib'))
        FileUtils.mkdir_p(File.join(dest, 'spec'))
        File.write(File.join(dest, 'lib', 'calc.rb'), original_content)
        File.write(File.join(dest, 'spec', 'calc_spec.rb'), spec_content)
      end

      result = begin
        runner.run_single_mutation(mutation, :shadow, tmp_dir)
      ensure
        runner.cleanup_shadow_workspaces
      end

      expect(result[:status]).to eq(:killed)
      expect(calls).to eq([['#add'], []])
    end
  end
end
