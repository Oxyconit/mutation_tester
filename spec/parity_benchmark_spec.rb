require 'spec_helper'
require 'fileutils'
require 'tmpdir'
require 'stringio'
require_relative 'support/parity_fixture'

RSpec.describe 'Ground-truth pricer detection parity benchmark' do
  def run_pricer_fixture(fixture_spec, runner_mode: :auto, processes: 1,
                         source: ParityFixture::SOURCE, basename: 'pricer')
    Dir.mktmpdir do |dir|
      lib_dir = File.join(dir, 'lib')
      spec_dir = File.join(dir, 'spec')
      FileUtils.mkdir_p(lib_dir)
      FileUtils.mkdir_p(spec_dir)
      FileUtils.touch(File.join(dir, 'Gemfile'))

      source_file = File.join(lib_dir, "#{basename}.rb")
      spec_file = File.join(spec_dir, "#{basename}_spec.rb")
      File.write(source_file, source)
      File.write(spec_file, fixture_spec)

      config = MutationTester::Configuration.new
      config.parallel_processes = processes
      config.runner = runner_mode
      config.output_dir = 'mutation_reports'
      config.verbose = false

      core = MutationTester::Core.new(source_file, spec_file, config)
      original_stdout = $stdout
      $stdout = StringIO.new
      begin
        Dir.chdir(dir) { core.run }
      ensure
        $stdout = original_stdout
      end
      core.results
    end
  end

  def survivors_of(results)
    results.select { |r| r[:status] == :survived }
  end

  def gap_survivors(results, expectation)
    survivors_of(results).select do |mutant|
      mutant[:type] == expectation[:family] &&
        mutant[:line] == expectation[:line] &&
        expectation[:matching].all? { |key, value| mutant[key] == value }
    end
  end

  context 'with the spec that leaves the nine seeded test gaps open' do
    before(:context) do
      @results = run_pricer_fixture(ParityFixture::WEAK_SPEC)
    end

    it 'passes the baseline and exercises the full default mutation set' do
      expect(@results).not_to be_empty
      families = @results.map { |r| r[:type] }.uniq
      expect(families).to include(*ParityFixture::GAP_CLASSES.each_value.map { |e| e[:family] }.uniq)
    end

    ParityFixture::GAP_CLASSES.each_value do |expectation|
      it "surfaces a surviving #{expectation[:family]} mutant for #{expectation[:gap]}" do
        expect(gap_survivors(@results, expectation)).not_to be_empty
      end
    end

    it 'keeps both class-constant boundary mutants of the threshold alive' do
      constant_survivors = survivors_of(@results).select do |mutant|
        mutant[:type] == :number && mutant[:line] == ParityFixture::THRESHOLD_CONSTANT_LINE
      end
      expect(constant_survivors.map { |mutant| mutant[:mutated] }).to contain_exactly('199', '201')
    end

    it 'keeps the comparison boundary probe swapping >= for > alive' do
      boundary_survivor = survivors_of(@results).find do |mutant|
        mutant[:type] == :comparison &&
          mutant[:line] == ParityFixture::THRESHOLD_COMPARISON_LINE &&
          mutant[:original] == '>=' && mutant[:mutated] == '>'
      end
      expect(boundary_survivor).not_to be_nil
    end
  end

  context 'with the complete spec' do
    before(:context) do
      @results = run_pricer_fixture(ParityFixture::COMPLETE_SPEC)
    end

    it 'kills every mutant of the default set, leaving no equivalent mutants' do
      expect(@results).not_to be_empty
      offending = @results.reject { |r| %i[killed timeout].include?(r[:status]) }
      expect(offending.map { |r| r.slice(:status, :type, :line, :description) }).to be_empty
    end

    it 'generates and kills the range boundary swap and both hash pair removals' do
      killed = @results.select { |r| r[:status] == :killed }.map { |r| r[:description] }
      expect(killed).to include('Change .. to ...', 'Remove pair total from merge', 'Remove pair count from merge')
    end
  end

  context 'with the in-memory runner' do
    before(:context) do
      @fork_results = run_pricer_fixture(ParityFixture::WEAK_SPEC, runner_mode: :fork)
      @in_memory_results = run_pricer_fixture(ParityFixture::WEAK_SPEC, runner_mode: :in_memory)
    end

    it 'reports exactly the same per-mutant statuses as the fork runner on the weak spec' do
      expect(@in_memory_results).not_to be_empty
      expect(@in_memory_results.map { |r| r.slice(:id, :type, :line, :status) })
        .to eq(@fork_results.map { |r| r.slice(:id, :type, :line, :status) })
    end

    ParityFixture::GAP_CLASSES.each_value do |expectation|
      it "surfaces a surviving #{expectation[:family]} mutant for #{expectation[:gap]}" do
        expect(gap_survivors(@in_memory_results, expectation)).not_to be_empty
      end
    end

    it 'keeps both class-constant boundary mutants of the threshold alive' do
      constant_survivors = survivors_of(@in_memory_results).select do |mutant|
        mutant[:type] == :number && mutant[:line] == ParityFixture::THRESHOLD_CONSTANT_LINE
      end
      expect(constant_survivors.map { |mutant| mutant[:mutated] }).to contain_exactly('199', '201')
    end

    it 'kills every mutant of the default set on the complete spec' do
      results = run_pricer_fixture(ParityFixture::COMPLETE_SPEC, runner_mode: :in_memory)
      offending = results.reject { |r| %i[killed timeout].include?(r[:status]) }
      expect(offending.map { |r| r.slice(:status, :type, :line, :description) }).to be_empty
    end
  end

  context 'with a fixture whose argument mutants crash at load time' do
    def run_load_crash_fixture(runner_mode)
      run_pricer_fixture(ParityFixture::LOAD_CRASH_SPEC,
                         source: ParityFixture::LOAD_CRASH_SOURCE,
                         basename: 'till',
                         runner_mode: runner_mode)
    end

    def taxonomy(results)
      results.map { |r| r.slice(:id, :type, :line, :status) }
    end

    before(:context) do
      @results_by_runner = %i[in_memory fork spawn].to_h do |mode|
        [mode, run_load_crash_fixture(mode)]
      end
    end

    it 'reports the identical full per-mutant taxonomy across the in-memory, fork and spawn runners' do
      expect(@results_by_runner[:in_memory]).not_to be_empty
      expect(taxonomy(@results_by_runner[:in_memory])).to eq(taxonomy(@results_by_runner[:spawn]))
      expect(taxonomy(@results_by_runner[:fork])).to eq(taxonomy(@results_by_runner[:spawn]))
    end

    it 'kills the nil-argument struct mutants in every runner, never excluding the unloadable one as an error' do
      @results_by_runner.each_value do |results|
        crashers = results.select do |mutant|
          mutant[:type] == :argument &&
            mutant[:line] == ParityFixture::LOAD_CRASH_STRUCT_LINE &&
            mutant[:description].to_s.include?('with nil')
        end
        expect(crashers.size).to eq(2)
        expect(crashers.map { |mutant| mutant[:status] }).to all(eq(:killed))
        expect(results.map { |mutant| mutant[:status] }).not_to include(:error)
      end
    end
  end

  context 'with the in-memory runner running in parallel' do
    before(:context) do
      @in_memory_serial_results = run_pricer_fixture(ParityFixture::WEAK_SPEC, runner_mode: :in_memory)
      @in_memory_parallel_results = run_pricer_fixture(ParityFixture::WEAK_SPEC, runner_mode: :in_memory, processes: 4)
    end

    it 'reports exactly the same per-mutant statuses as the serial in-memory run on the weak spec' do
      expect(@in_memory_parallel_results).not_to be_empty
      expect(@in_memory_parallel_results.map { |r| r.slice(:id, :type, :line, :status) })
        .to eq(@in_memory_serial_results.map { |r| r.slice(:id, :type, :line, :status) })
    end

    ParityFixture::GAP_CLASSES.each_value do |expectation|
      it "surfaces a surviving #{expectation[:family]} mutant for #{expectation[:gap]}" do
        expect(gap_survivors(@in_memory_parallel_results, expectation)).not_to be_empty
      end
    end

    it 'kills every mutant of the default set on the complete spec' do
      results = run_pricer_fixture(ParityFixture::COMPLETE_SPEC, runner_mode: :in_memory, processes: 4)
      offending = results.reject { |r| %i[killed timeout].include?(r[:status]) }
      expect(offending.map { |r| r.slice(:status, :type, :line, :description) }).to be_empty
    end
  end
end
