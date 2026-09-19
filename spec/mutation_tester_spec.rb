require 'spec_helper'
require 'tmpdir'

RSpec.describe MutationTester do
  it 'has a version number' do
    expect(MutationTester::VERSION).not_to be nil
  end

  describe '.configure' do
    around do |example|
      example.run
    ensure
      MutationTester.reset_configuration!
    end

    it 'allows configuration' do
      MutationTester.configure do |config|
        config.parallel_processes = 8
      end

      expect(MutationTester.configuration.parallel_processes).to eq(8)
    end
  end
end

RSpec.describe 'MutationTester.reset_configuration!' do
  around do |example|
    example.run
  ensure
    MutationTester.reset_configuration!
  end

  it 'restores fresh default values after the configuration was changed' do
    MutationTester.configure do |config|
      config.minimum_score = 10.0
      config.reporters = [:json]
      config.fail_on_threshold = false
    end

    MutationTester.reset_configuration!

    config = MutationTester.configuration
    expect(config.minimum_score).to eq(80.0)
    expect(config.reporters).to eq(%i[console html json])
    expect(config.fail_on_threshold).to be(true)
  end
end

RSpec.describe 'MutationTester.run per-run options' do
  around do |example|
    MutationTester.reset_configuration!
    example.run
  ensure
    MutationTester.reset_configuration!
  end

  it 'applies the options to the run config without mutating the global configuration' do
    captured = nil
    fake_core = instance_double(MutationTester::Core, run: true)
    allow(MutationTester::Core).to receive(:new) do |_source, _spec, config|
      captured = config
      fake_core
    end

    Dir.mktmpdir do |dir|
      source = File.join(dir, 'src.rb')
      spec = File.join(dir, 'src_spec.rb')
      File.write(source, "x = 1\n")
      File.write(spec, '')

      result = MutationTester.run(source, spec, reporters: [:json], fail_on_threshold: false)

      expect(result).to be(true)
    end

    expect(captured.reporters).to eq([:json])
    expect(captured.fail_on_threshold).to be(false)

    expect(MutationTester.configuration.reporters).to eq(%i[console html json])
    expect(MutationTester.configuration.fail_on_threshold).to be(true)
  end
end

RSpec.describe MutationTester::Configuration do
  around do |example|
    saved = ENV['MUTATION_TESTER_PARALLEL_PROCESSES']
    example.run
  ensure
    if saved.nil?
      ENV.delete('MUTATION_TESTER_PARALLEL_PROCESSES')
    else
      ENV['MUTATION_TESTER_PARALLEL_PROCESSES'] = saved
    end
  end

  describe '#parallel_processes from ENV' do
    it 'defaults to the core-derived auto value without warning when the ENV var is unset' do
      ENV.delete('MUTATION_TESTER_PARALLEL_PROCESSES')

      config = nil
      expect { config = described_class.new }.not_to output.to_stderr
      expect(config.parallel_processes).to eq(described_class.auto_parallel_processes)
    end

    it 'keeps a valid ENV value without warning' do
      ENV['MUTATION_TESTER_PARALLEL_PROCESSES'] = '4'

      config = nil
      expect { config = described_class.new }.not_to output.to_stderr
      expect(config.parallel_processes).to eq(4)
    end

    it 'falls back to 1 with a stderr warning for an unparseable ENV value' do
      ENV['MUTATION_TESTER_PARALLEL_PROCESSES'] = 'abc'

      config = nil
      expect { config = described_class.new }
        .to output(/parallel_processes must be >= 1/).to_stderr
      expect(config.parallel_processes).to eq(1)
    end

    it 'falls back to 1 with a stderr warning for a zero ENV value' do
      ENV['MUTATION_TESTER_PARALLEL_PROCESSES'] = '0'

      config = nil
      expect { config = described_class.new }.to output.to_stderr
      expect(config.parallel_processes).to eq(1)
    end
  end

  describe '#parallel_processes= setter' do
    it 'coerces values below 1 to 1 and warns on stderr' do
      ENV.delete('MUTATION_TESTER_PARALLEL_PROCESSES')
      config = described_class.new

      expect { config.parallel_processes = 0 }
        .to output(/parallel_processes must be >= 1/).to_stderr
      expect(config.parallel_processes).to eq(1)
    end

    it 'coerces negative values to 1 and warns on stderr' do
      ENV.delete('MUTATION_TESTER_PARALLEL_PROCESSES')
      config = described_class.new

      expect { config.parallel_processes = -3 }.to output.to_stderr
      expect(config.parallel_processes).to eq(1)
    end

    it 'accepts a valid value without warning' do
      ENV.delete('MUTATION_TESTER_PARALLEL_PROCESSES')
      config = described_class.new

      expect { config.parallel_processes = 6 }.not_to output.to_stderr
      expect(config.parallel_processes).to eq(6)
    end
  end

  it 'defaults verbose to false (quiet by default)' do
    expect(described_class.new.verbose).to be(false)
  end
end

RSpec.describe 'MutationTester::Core#mutation_score' do
  def core_with_results(results)
    dir = Dir.mktmpdir
    source = File.join(dir, 'src.rb')
    spec = File.join(dir, 'src_spec.rb')
    File.write(source, "x = 1\n")
    File.write(spec, '')
    core = MutationTester::Core.new(source, spec, MutationTester::Configuration.new)
    core.instance_variable_set(:@results, results)
    core
  end

  it 'counts a timeout as a kill and excludes stillborn and error' do
    results = [
      { id: 1, status: :killed, killed: true },
      { id: 2, status: :killed, killed: true },
      { id: 3, status: :killed, killed: true },
      { id: 4, status: :timeout, killed: true, timeout: true },
      { id: 5, status: :survived, killed: false },
      { id: 6, status: :survived, killed: false },
      { id: 7, status: :stillborn, killed: false },
      { id: 8, status: :error, killed: false }
    ]

    expect(core_with_results(results).mutation_score).to eq(66.67)
    expect(core_with_results(results).mutation_score)
      .to eq(MutationTester::Reporters::BaseReporter.score(results))
  end

  it 'returns 0.0 when every mutant is stillborn or error (empty denominator)' do
    results = [
      { id: 1, status: :stillborn, killed: false },
      { id: 2, status: :error, killed: false }
    ]

    expect(core_with_results(results).mutation_score).to eq(0.0)
  end
end

RSpec.describe 'MutationTester::Core#run_original_tests deadline + shell-free baseline' do
  def core_for(spec_file, config = MutationTester::Configuration.new)
    dir = File.dirname(spec_file)
    source = File.join(dir, 'src.rb')
    File.write(source, "x = 1\n") unless File.exist?(source)
    MutationTester::Core.new(source, spec_file, config)
  end

  it 'delegates to TestCommand#run with the baseline deadline, never a bare system' do
    Dir.mktmpdir do |dir|
      spec = File.join(dir, 'thing_spec.rb')
      File.write(spec, '')
      config = MutationTester::Configuration.new
      config.baseline_timeout = 123
      core = core_for(spec, config)
      allow(core).to receive(:puts)

      expect(core).not_to receive(:system)

      command = core.send(:test_command)
      allow(core).to receive(:test_command).and_return(command)
      allow(command).to receive(:run)
        .and_return(MutationTester::TestCommand::Result.new(true, false))

      expect(core.send(:run_original_tests)).to be true
      expect(command).to have_received(:run).with(timeout: 123, capture: true)
    end
  end

  it 'measures the baseline wall-clock duration on the monotonic clock and stores it on the configuration' do
    Dir.mktmpdir do |dir|
      spec = File.join(dir, 'thing_spec.rb')
      File.write(spec, '')
      config = MutationTester::Configuration.new
      core = core_for(spec, config)
      allow(core).to receive(:puts)

      command = core.send(:test_command)
      allow(core).to receive(:test_command).and_return(command)
      allow(command).to receive(:run)
        .and_return(MutationTester::TestCommand::Result.new(true, false))
      allow(Process).to receive(:clock_gettime)
        .with(Process::CLOCK_MONOTONIC).and_return(100.0, 105.5)

      expect(core.send(:run_original_tests)).to be true
      expect(config.baseline_duration).to eq(5.5)
      expect(config.effective_timeout).to eq(27.5)
    end
  end

  it 'stores no baseline duration when the baseline run fails' do
    Dir.mktmpdir do |dir|
      spec = File.join(dir, 'thing_spec.rb')
      File.write(spec, '')
      config = MutationTester::Configuration.new
      core = core_for(spec, config)
      allow(core).to receive(:puts)

      command = core.send(:test_command)
      allow(core).to receive(:test_command).and_return(command)
      allow(command).to receive(:run)
        .and_return(MutationTester::TestCommand::Result.new(false, false, ''))

      expect(core.send(:run_original_tests)).to be false
      expect(config.baseline_duration).to be_nil
      expect(config.effective_timeout).to eq(30)
    end
  end

  it 'spawns the canonical shell-free argv, keeping a hostile spec path as one literal argument' do
    Dir.mktmpdir do |dir|
      spec = File.join(dir, 'a b;c_spec.rb')
      File.write(spec, '')
      spawn_config = MutationTester::Configuration.new
      spawn_config.runner = :spawn
      core = core_for(spec, spawn_config)
      allow(core).to receive(:puts)

      spawned = nil
      allow(Process).to receive(:spawn).and_wrap_original do |original, *args|
        spawned = args.reject { |a| a.is_a?(Hash) }
        original.call('true')
      end

      core.send(:run_original_tests)

      expect(spawned).to eq(core.send(:test_command).argv)
      expect(spawned.size).to be > 1
      expect(spawned.last).to eq(spec)
      expect(spawned.last).to include('a b;c_spec.rb')
    end
  end
end

RSpec.describe MutationTester::Configuration, '#baseline_timeout' do
  it 'defaults to a value looser than the per-mutant timeout' do
    config = described_class.new

    expect(config.baseline_timeout).to eq(300)
    expect(config.baseline_timeout).to be > config.timeout
  end

  it 'is configurable' do
    config = described_class.new
    config.baseline_timeout = 120

    expect(config.baseline_timeout).to eq(120)
  end

  it 'accepts nil to disable the deadline' do
    config = described_class.new
    config.baseline_timeout = nil

    expect(config.baseline_timeout).to be_nil
  end

  it 'is carried across merge' do
    merged = described_class.new.merge(baseline_timeout: 90)

    expect(merged.baseline_timeout).to eq(90)
  end
end

RSpec.describe 'MutationTester.run threshold handling' do
  def core_with_mocked_score(score, fail_on_threshold: true, minimum_score: 80.0)
    dir = Dir.mktmpdir
    source = File.join(dir, 'src.rb')
    spec = File.join(dir, 'src_spec.rb')
    File.write(source, "x = 1\n")
    File.write(spec, '')

    config = MutationTester::Configuration.new
    config.fail_on_threshold = fail_on_threshold
    config.minimum_score = minimum_score

    core = MutationTester::Core.new(source, spec, config)
    allow(core).to receive(:print_header)
    allow(core).to receive(:run_original_tests).and_return(true)
    allow(core).to receive(:generate_mutations)
    allow(core).to receive(:run_mutations)
    allow(core).to receive(:generate_reports)
    allow(core).to receive(:puts)
    core.instance_variable_set(:@mutations, [{ id: 1 }])
    allow(core).to receive(:mutation_score).and_return(score)

    allow(MutationTester::Core).to receive(:new).and_return(core)
    core
  end

  it 'returns false without terminating the process when the score is below the threshold' do
    core = core_with_mocked_score(10.0, fail_on_threshold: true, minimum_score: 80.0)
    expect(core).not_to receive(:exit)

    expect(MutationTester.run(core.source_file, core.spec_file)).to be false
  end

  it 'returns true when the score meets the threshold' do
    core = core_with_mocked_score(95.0, fail_on_threshold: true, minimum_score: 80.0)

    expect(MutationTester.run(core.source_file, core.spec_file)).to be true
  end

  it 'returns true when fail_on_threshold is disabled even if the score is low' do
    core = core_with_mocked_score(0.0, fail_on_threshold: false, minimum_score: 80.0)

    expect(MutationTester.run(core.source_file, core.spec_file)).to be true
  end
end

RSpec.describe 'MutationTester::Core#run unparseable source' do
  def core_for(source_content)
    dir = Dir.mktmpdir
    source = File.join(dir, 'src.rb')
    spec = File.join(dir, 'src_spec.rb')
    File.write(source, source_content)
    File.write(spec, '')

    core = MutationTester::Core.new(source, spec, MutationTester::Configuration.new)
    allow(core).to receive(:print_header)
    allow(core).to receive(:run_original_tests).and_return(true)
    allow(core).to receive(:puts)
    core
  end

  it 'returns false for a source file with a syntax error' do
    core = core_for("def broken(\n")
    expect(core).not_to receive(:run_mutations)

    expect(core.run).to be false
  end

  it 'returns true for a valid file that generates no mutations' do
    core = core_for("CONST = Object.new\n")

    expect(core.run).to be true
  end
end

RSpec.describe 'MutationTester::Core#run with results but zero scored mutants' do
  def core_with_run_results(results, fail_on_threshold: true)
    dir = Dir.mktmpdir
    source = File.join(dir, 'src.rb')
    spec = File.join(dir, 'src_spec.rb')
    File.write(source, "x = 1\n")
    File.write(spec, '')

    config = MutationTester::Configuration.new
    config.parallel_processes = 1
    config.fail_on_threshold = fail_on_threshold

    core = MutationTester::Core.new(source, spec, config)
    allow(core).to receive(:print_header)
    allow(core).to receive(:run_original_tests).and_return(true)
    allow(core).to receive(:generate_mutations)
    allow(core).to receive(:generate_reports)
    core.instance_variable_set(:@mutations, results.map { |r| { id: r[:id] } })
    allow(core).to receive(:run_mutations) do
      core.instance_variable_set(:@results, results)
    end
    core
  end

  def run_capturing_stdout(core)
    original = $stdout
    $stdout = StringIO.new
    returned = core.run
    [returned, $stdout.string]
  ensure
    $stdout = original
  end

  let(:degraded_results) do
    [
      { id: 1, status: :error, killed: false, description: 'Error: boom' },
      { id: 2, status: :error, killed: false, description: 'Error: boom' },
      { id: 3, status: :stillborn, killed: false }
    ]
  end

  it 'fails the run naming the error and stillborn counts instead of a threshold verdict' do
    core = core_with_run_results(degraded_results)

    returned, output = run_capturing_stdout(core)

    expect(returned).to be(false)
    expect(output).to include('none of the 3 mutants could be scored (2 error, 1 stillborn)')
    expect(output).to match(/infrastructure or runner problem/)
    expect(output).not_to match(/below threshold/)
    expect(core.infrastructure_failure?).to be(true)
  end

  it 'fails even when threshold enforcement is disabled, because no verdict was reached' do
    core = core_with_run_results(degraded_results, fail_on_threshold: false)

    returned, = run_capturing_stdout(core)

    expect(returned).to be(false)
    expect(core.infrastructure_failure?).to be(true)
  end

  it 'keeps the below-threshold wording and a false predicate for a genuine threshold failure' do
    scored = [
      { id: 1, status: :killed, killed: true },
      { id: 2, status: :survived, killed: false },
      { id: 3, status: :survived, killed: false },
      { id: 4, status: :survived, killed: false }
    ]
    core = core_with_run_results(scored)

    returned, output = run_capturing_stdout(core)

    expect(returned).to be(false)
    expect(output).to match(/Mutation score 25\.0% is below threshold 80\.0%/)
    expect(output).not_to match(/infrastructure or runner problem/)
    expect(core.infrastructure_failure?).to be(false)
  end
end

RSpec.describe 'MutationTester::Core in-place backup recovery' do
  let(:original) { "class Calc\n  def add(a, b)\n    a + b\n  end\nend\n" }
  let(:mutated)  { "class Calc\n  def add(a, b)\n    a - b\n  end\nend\n" }

  it 'recovers the source from a leftover backup before capturing the baseline' do
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'calc.rb')
      spec = File.join(dir, 'calc_spec.rb')
      File.write(source, mutated)
      File.write(spec, '')
      File.write("#{source}.mutation_backup", original)

      core = MutationTester::Core.new(source, spec, MutationTester::Configuration.new)

      expect(File.read(source)).to eq(original)
      expect(File.exist?("#{source}.mutation_backup")).to be(false)
      expect(core.instance_variable_get(:@original_content)).to eq(original)
    end
  end

  it 'leaves a normal construction untouched when there is no backup' do
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'calc.rb')
      spec = File.join(dir, 'calc_spec.rb')
      File.write(source, original)
      File.write(spec, '')

      core = MutationTester::Core.new(source, spec, MutationTester::Configuration.new)

      expect(File.read(source)).to eq(original)
      expect(core.instance_variable_get(:@original_content)).to eq(original)
    end
  end
end

RSpec.describe 'lib/ process-termination hygiene' do
  it 'contains no exit or exit! call anywhere under lib/' do
    lib_dir = File.expand_path('../lib', __dir__)
    offenders = Dir.glob(File.join(lib_dir, '**', '*'))
                   .select { |path| File.file?(path) }
                   .select { |path| File.read(path).match?(/\bexit!?\b/) }

    expect(offenders).to be_empty,
                         "Expected no exit/exit! under lib/, found in: #{offenders.join(', ')}"
  end
end

RSpec.describe MutationTester::Mutator do
  def build_mutator(source, config = MutationTester::Configuration.new)
    dir = Dir.mktmpdir
    path = File.join(dir, 'src.rb')
    File.write(path, source)
    MutationTester::Mutator.new(path, config)
  end

  it 'generates a swap and two operand removals for a multiline && operator' do
    source = "check(\n  a\n) && b\n"
    mutator = build_mutator(source)
    ast = Parser::CurrentRuby.parse(source)

    mutations = mutator.generate_mutations(ast)
    logical = mutations.select { |m| m[:type] == :logical }

    expect(logical.size).to eq(3)
    swap = logical.find { |m| m[:description] == 'Change && to ||' }
    expect(swap[:code]).to include('||')
    expect(swap[:code]).not_to include('&&')
    logical.each do |m|
      expect { Parser::CurrentRuby.parse(m[:code]) }.not_to raise_error
    end
  end

  it 'still generates boolean mutants (true<->false) with correct mutated_line and description' do
    source = "a = true\nb = false\n"
    mutator = build_mutator(source)
    ast = Parser::CurrentRuby.parse(source)

    boolean = mutator.generate_mutations(ast).select { |m| m[:type] == :boolean }
    true_to_false = boolean.find { |m| m[:original] == 'true' }
    false_to_true = boolean.find { |m| m[:original] == 'false' }

    expect(true_to_false).not_to be_nil
    expect(true_to_false[:mutated]).to eq('false')
    expect(true_to_false[:code]).to eq("a = false\nb = false\n")
    expect(true_to_false[:mutated_line]).to eq('a = false')
    expect(true_to_false[:description]).to eq('Change true to false')

    expect(false_to_true).not_to be_nil
    expect(false_to_true[:mutated]).to eq('true')
    expect(false_to_true[:code]).to eq("a = true\nb = true\n")
    expect(false_to_true[:mutated_line]).to eq('b = true')
    expect(false_to_true[:description]).to eq('Change false to true')
  end

  it 'counts skipped mutations and reports them when generation fails' do
    source = "flag = true\n"
    mutator = build_mutator(source)
    ast = Parser::CurrentRuby.parse(source)

    allow(Unparser).to receive(:unparse).and_raise('boom')

    expect { mutator.generate_mutations(ast) }.to output(/skipped 1/).to_stdout
    expect(mutator.skipped_count).to eq(1)
  end

  it 'suppresses per-mutation warnings when verbose is false but still counts and reports skips' do
    config = MutationTester::Configuration.new
    config.verbose = false
    source = "flag = true\n"
    mutator = build_mutator(source, config)
    ast = Parser::CurrentRuby.parse(source)

    allow(Unparser).to receive(:unparse).and_raise('boom')

    expect { mutator.generate_mutations(ast) }.not_to output(/Warning: skipped/).to_stdout
    expect(mutator.skipped_count).to eq(1)
  end

  it 'still prints the aggregate skipped-count summary when verbose is false' do
    config = MutationTester::Configuration.new
    config.verbose = false
    source = "flag = true\n"
    mutator = build_mutator(source, config)
    ast = Parser::CurrentRuby.parse(source)

    allow(Unparser).to receive(:unparse).and_raise('boom')

    expect { mutator.generate_mutations(ast) }.to output(/Generated \d+ mutations, skipped 1/).to_stdout
  end

  it 'prints per-mutation warnings and the aggregate summary when verbose is true' do
    config = MutationTester::Configuration.new
    config.verbose = true
    source = "flag = true\n"
    mutator = build_mutator(source, config)
    ast = Parser::CurrentRuby.parse(source)

    allow(Unparser).to receive(:unparse).and_raise('boom')

    expect { mutator.generate_mutations(ast) }.to output(/Warning: skipped/).to_stdout
    expect { mutator.generate_mutations(ast) }.to output(/Generated \d+ mutations, skipped 1/).to_stdout
  end

  it 'produces exactly one mutant changing literal 0 to 1' do
    source = "x = 0\n"
    mutator = build_mutator(source)
    ast = Parser::CurrentRuby.parse(source)

    mutations = mutator.generate_mutations(ast)
    zero_to_one = mutations.select { |m| m[:type] == :number && m[:original] == '0' && m[:mutated] == '1' }

    expect(zero_to_one.size).to eq(1)
    expect(zero_to_one.first[:code]).to eq("x = 1\n")
  end

  it 'rejects no-op mutants whose code equals the original file content' do
    source = "flag = true\n"
    mutator = build_mutator(source)
    ast = Parser::CurrentRuby.parse(source)

    allow(mutator).to receive(:replace_node).and_return(source)

    mutations = mutator.generate_mutations(ast)

    expect(mutations.map { |m| m[:code] }).not_to include(source)
    expect(mutations).to be_empty
  end

  it 'never returns two mutations with identical code' do
    source = "x = 0\ny = 2\nz = true\n"
    mutator = build_mutator(source)
    ast = Parser::CurrentRuby.parse(source)

    codes = mutator.generate_mutations(ast).map { |m| m[:code] }

    expect(codes).to eq(codes.uniq)
  end

  it 'returns the post-filter count with gap-free ids' do
    source = "x = 0\n"
    mutator = build_mutator(source)
    ast = Parser::CurrentRuby.parse(source)

    raw = mutator.send(:collect_mutations, ast)
    mutations = mutator.generate_mutations(ast)

    expect(mutations.size).to be < raw.size
    expect(mutations.size).to eq(mutations.map { |m| m[:code] }.uniq.size)
    expect(mutations.map { |m| m[:id] }).to eq((1..mutations.size).to_a)
  end

  it 'wraps a negated comparison condition in parentheses' do
    source = "if a > 1\n  :big\nelse\n  :small\nend\n"
    mutator = build_mutator(source)
    ast = Parser::CurrentRuby.parse(source)

    conditional = mutator.generate_mutations(ast).select { |m| m[:type] == :conditional }

    expect(conditional.size).to eq(1)
    expect(conditional.first[:code]).to include('!(a > 1)')
    expect(conditional.first[:code]).not_to include('!a > 1')
    expect(conditional.first[:mutated]).to eq('!(a > 1)')
  end

  it 'produces a parseable negated conditional that round-trips through Unparser' do
    source = "if a > 1\n  :big\nend\n"
    mutator = build_mutator(source)
    ast = Parser::CurrentRuby.parse(source)

    mutant = mutator.generate_mutations(ast).find { |m| m[:type] == :conditional }

    expect { Parser::CurrentRuby.parse(mutant[:code]) }.not_to raise_error
    reparsed = Unparser.unparse(Parser::CurrentRuby.parse(mutant[:code]))
    expect(reparsed).to include('!(a > 1)')
  end

  it 'negates a method-call condition as a whole' do
    source = "if foo?\n  :yes\nend\n"
    mutator = build_mutator(source)
    ast = Parser::CurrentRuby.parse(source)

    conditional = mutator.generate_mutations(ast).find { |m| m[:type] == :conditional }

    expect(conditional[:code]).to include('!(foo?)')
  end

  it 'negates an && condition as a whole rather than only its left operand' do
    source = "if a && b\n  :yes\nend\n"
    mutator = build_mutator(source)
    ast = Parser::CurrentRuby.parse(source)

    conditional = mutator.generate_mutations(ast).select { |m| m[:type] == :conditional }

    expect(conditional.size).to eq(1)
    expect(conditional.first[:code]).to include('!(a && b)')
    expect(conditional.first[:code]).not_to include('!a && b')
  end

  it 'mutates keyword and to or, preserving token style' do
    source = "a and b\n"
    mutator = build_mutator(source)
    ast = Parser::CurrentRuby.parse(source)

    swap = mutator.generate_mutations(ast)
               .find { |m| m[:type] == :logical && m[:description] == 'Change and to or' }

    expect(swap[:code]).to eq("a or b\n")
    expect(swap[:original]).to eq('and')
    expect(swap[:mutated]).to eq('or')
  end

  it 'mutates keyword or to and, preserving token style' do
    source = "a or b\n"
    mutator = build_mutator(source)
    ast = Parser::CurrentRuby.parse(source)

    swap = mutator.generate_mutations(ast)
               .find { |m| m[:type] == :logical && m[:description] == 'Change or to and' }

    expect(swap[:code]).to eq("a and b\n")
    expect(swap[:original]).to eq('or')
    expect(swap[:mutated]).to eq('and')
  end

  it 'preserves precedence when mutating keyword and in an assignment' do
    source = "x = a and b\n"
    mutator = build_mutator(source)
    ast = Parser::CurrentRuby.parse(source)

    swap = mutator.generate_mutations(ast)
               .find { |m| m[:type] == :logical && m[:description] == 'Change and to or' }

    expect(swap[:code]).to eq("x = a or b\n")
    expect(swap[:mutated_line]).to eq('x = a or b')
  end

  it 'mutates && to || with symbolic original/mutated fields' do
    source = "a && b\n"
    mutator = build_mutator(source)
    ast = Parser::CurrentRuby.parse(source)

    swap = mutator.generate_mutations(ast)
               .find { |m| m[:type] == :logical && m[:description] == 'Change && to ||' }

    expect(swap[:code]).to eq("a || b\n")
    expect(swap[:original]).to eq('&&')
    expect(swap[:mutated]).to eq('||')
  end

  it 'mutates a multiline || to && at the operator position' do
    source = "check(\n  a\n) || b\n"
    mutator = build_mutator(source)
    ast = Parser::CurrentRuby.parse(source)

    swap = mutator.generate_mutations(ast)
               .find { |m| m[:type] == :logical && m[:description] == 'Change || to &&' }

    expect(swap[:code]).to eq("check(\n  a\n) && b\n")
    expect(swap[:original]).to eq('||')
    expect(swap[:mutated]).to eq('&&')
    expect { Parser::CurrentRuby.parse(swap[:code]) }.not_to raise_error
  end

  it 'does not mutate the string argument of require_relative to ""' do
    source = %(require_relative "helper"\n)
    mutator = build_mutator(source)
    ast = Parser::CurrentRuby.parse(source)

    strings = mutator.generate_mutations(ast).select { |m| m[:type] == :string }

    expect(strings).to be_empty
  end

  %w[require require_relative load autoload].each do |loader|
    it "does not mutate the string path argument of #{loader}" do
      arg = loader == 'autoload' ? ':Foo, "path"' : '"path"'
      source = %(#{loader} #{arg}\n)
      mutator = build_mutator(source)
      ast = Parser::CurrentRuby.parse(source)

      strings = mutator.generate_mutations(ast).select { |m| m[:type] == :string }

      expect(strings).to be_empty
    end
  end

  it 'still mutates a require with an explicit receiver' do
    source = %(Kernel.require "json"\n)
    mutator = build_mutator(source)
    ast = Parser::CurrentRuby.parse(source)

    strings = mutator.generate_mutations(ast).select { |m| m[:type] == :string }

    expect(strings.size).to eq(1)
    expect(strings.first[:code]).to eq(%(Kernel.require ""\n))
  end

  it 'still mutates regular string literals to ""' do
    source = "def greeting\n  \"hello\"\nend\n"
    mutator = build_mutator(source)
    ast = Parser::CurrentRuby.parse(source)

    strings = mutator.generate_mutations(ast).select { |m| m[:type] == :string }

    expect(strings.size).to eq(1)
    expect(strings.first[:mutated]).to eq("''")
    expect(strings.first[:code]).to eq("def greeting\n  \"\"\nend\n")
  end

  it 'does not count a skipped require string against skipped_count' do
    source = %(require_relative "helper"\n)
    mutator = build_mutator(source)
    ast = Parser::CurrentRuby.parse(source)

    mutator.generate_mutations(ast)

    expect(mutator.skipped_count).to eq(0)
  end

  %w[<<~TEXT <<-TEXT <<TEXT].each do |marker|
    it "produces no string mutant and no orphaned body for a #{marker} heredoc" do
      source = "def banner\n  msg = #{marker}\n    hello\n    world\nTEXT\n  msg\nend\n"
      mutator = build_mutator(source)
      ast = Parser::CurrentRuby.parse(source)

      mutations = mutator.generate_mutations(ast)
      strings = mutations.select { |m| m[:type] == :string }

      expect(strings).to be_empty
      mutations.each do |m|
        expect { Parser::CurrentRuby.parse(m[:code]) }.not_to raise_error
      end
    end
  end

  it 'still mutates a regular string literal that sits next to a heredoc' do
    source = "def banner\n  note = \"hi\"\n  msg = <<~TEXT\n    hello\n  TEXT\n  [note, msg]\nend\n"
    mutator = build_mutator(source)
    ast = Parser::CurrentRuby.parse(source)

    strings = mutator.generate_mutations(ast).select { |m| m[:type] == :string }

    expect(strings.size).to eq(1)
    expect(strings.first[:mutated]).to eq("''")
    expect(strings.first[:code]).to include('note = ""')
    expect(strings.first[:code]).to include('<<~TEXT')
  end

  it 'does not count a skipped heredoc against skipped_count' do
    source = "def banner\n  <<~TEXT\n    hello\n  TEXT\nend\n"
    mutator = build_mutator(source)
    ast = Parser::CurrentRuby.parse(source)

    mutator.generate_mutations(ast)

    expect(mutator.skipped_count).to eq(0)
  end

  it 'mutates the op_asgn operator of a += to -=, *= and /=' do
    source = "a += 2\n"
    mutator = build_mutator(source)
    ast = Parser::CurrentRuby.parse(source)

    ops = mutator.generate_mutations(ast).select { |m| m[:original] == '+=' }

    expect(ops.map { |m| m[:mutated] }).to contain_exactly('-=', '*=', '/=')
    expect(ops.map { |m| m[:code] }).to contain_exactly("a -= 2\n", "a *= 2\n", "a /= 2\n")
    ops.each { |m| expect { Parser::CurrentRuby.parse(m[:code]) }.not_to raise_error }
  end

  it 'keeps the rhs number mutants alongside the op_asgn operator mutants without duplicating them' do
    source = "a += 2\n"
    mutator = build_mutator(source)
    ast = Parser::CurrentRuby.parse(source)

    mutations = mutator.generate_mutations(ast)
    numbers = mutations.select { |m| m[:type] == :number }

    expect(numbers.map { |m| m[:code] }).to contain_exactly("a += 0\n", "a += 1\n", "a += 3\n")
    codes = mutations.map { |m| m[:code] }
    expect(codes).to eq(codes.uniq)
    expect(mutations.map { |m| m[:id] }).to eq((1..mutations.size).to_a)
  end

  it 'mutates != symmetrically to == (==, > and <)' do
    source = "a != b\n"
    mutator = build_mutator(source)
    ast = Parser::CurrentRuby.parse(source)

    comparisons = mutator.generate_mutations(ast).select { |m| m[:type] == :comparison }

    expect(comparisons.map { |m| m[:mutated] }).to include('==', '>', '<')
    expect(comparisons.map { |m| m[:code] }).to include("a == b\n", "a > b\n", "a < b\n")
    comparisons.each { |m| expect { Parser::CurrentRuby.parse(m[:code]) }.not_to raise_error }
  end
end

RSpec.describe 'MutationTester parser 3.3 syntax support' do
  def build_mutator(source)
    dir = Dir.mktmpdir
    path = File.join(dir, 'src.rb')
    File.write(path, source)
    MutationTester::Mutator.new(path, MutationTester::Configuration.new)
  end

  def core_for(source_content)
    dir = Dir.mktmpdir
    source = File.join(dir, 'src.rb')
    spec = File.join(dir, 'src_spec.rb')
    File.write(source, source_content)
    File.write(spec, '')
    core = MutationTester::Core.new(source, spec, MutationTester::Configuration.new)
    allow(core).to receive(:print_header)
    allow(core).to receive(:run_original_tests).and_return(true)
    allow(core).to receive(:puts)
    core
  end

  it 'parses and mutates a file using Ruby 3.1+ syntax on the supported 3.3 line' do
    # The shorthand hash `{ a:, b: }` is Ruby 3.1 syntax; Parser::CurrentRuby
    # follows the running Ruby, so parser/ruby30 cannot parse it. The capability
    # genuinely does not exist on Ruby 3.0, so skip there rather than fail.
    skip 'Ruby 3.1+ shorthand hash syntax is unparseable on Ruby 3.0' if Gem::Version.new(RUBY_VERSION) < Gem::Version.new('3.1')

    source = "def totals(a, b)\n  { a:, b:, sum: a + b }\nend\n"

    ast = Parser::CurrentRuby.parse(source)
    expect(ast).not_to be_nil

    mutations = build_mutator(source).generate_mutations(ast)

    expect(mutations).not_to be_empty
    mutations.each do |m|
      expect { Parser::CurrentRuby.parse(m[:code]) }.not_to raise_error
    end
  end

  it 'still reports run == false for a source file with invalid syntax' do
    core = core_for("def broken(\n")
    expect(core).not_to receive(:run_mutations)

    expect(core.run).to be false
  end
end

RSpec.describe 'MutationTester::Core#generate_reports' do
  def core_for(reporters, output_dir)
    dir = Dir.mktmpdir
    source = File.join(dir, 'src.rb')
    spec = File.join(dir, 'src_spec.rb')
    File.write(source, "x = 1\n")
    File.write(spec, '')
    config = MutationTester::Configuration.new
    config.reporters = reporters
    config.output_dir = output_dir
    core = MutationTester::Core.new(source, spec, config)
    allow(core).to receive(:puts)
    core
  end

  it 'creates exactly the configured reporters and calls generate on each' do
    Dir.mktmpdir do |out|
      core = core_for(%i[console json], out)

      console = instance_spy(MutationTester::Reporters::ConsoleReporter)
      json = instance_spy(MutationTester::Reporters::JsonReporter)
      allow(MutationTester::Reporters::ConsoleReporter).to receive(:new).and_return(console)
      allow(MutationTester::Reporters::JsonReporter).to receive(:new).and_return(json)
      expect(MutationTester::Reporters::HtmlReporter).not_to receive(:new)

      core.send(:generate_reports)

      expect(console).to have_received(:generate)
      expect(json).to have_received(:generate)
    end
  end

  it 'silently skips an unknown reporter type without raising or building a known reporter' do
    Dir.mktmpdir do |out|
      core = core_for([:xml], out)

      expect(MutationTester::Reporters::ConsoleReporter).not_to receive(:new)
      expect(MutationTester::Reporters::HtmlReporter).not_to receive(:new)
      expect(MutationTester::Reporters::JsonReporter).not_to receive(:new)

      expect { core.send(:generate_reports) }.not_to raise_error
    end
  end

  describe '#create_reporter' do
    it 'maps each known type to its reporter and returns nil for an unknown type' do
      Dir.mktmpdir do |out|
        core = core_for(%i[console], out)

        expect(core.send(:create_reporter, :console)).to be_a(MutationTester::Reporters::ConsoleReporter)
        expect(core.send(:create_reporter, :html)).to be_a(MutationTester::Reporters::HtmlReporter)
        expect(core.send(:create_reporter, :json)).to be_a(MutationTester::Reporters::JsonReporter)
        expect(core.send(:create_reporter, :xml)).to be_nil
      end
    end

    it 'passes the interruption state of the run through to every reporter' do
      Dir.mktmpdir do |out|
        core = core_for(%i[json], out)
        core.config.fail_fast = true
        core.instance_variable_set(:@mutations, [{}, {}, {}])
        core.instance_variable_set(:@results, [{ status: :killed }, { status: :survived }])

        %i[console html json].each do |type|
          expect(core.send(:create_reporter, type).interrupted?).to be true
        end
      end
    end
  end
end

RSpec.describe 'MutationTester::Core#interrupted?' do
  def core_with(fail_fast:, results:, total_mutations:)
    dir = Dir.mktmpdir
    source = File.join(dir, 'src.rb')
    spec = File.join(dir, 'src_spec.rb')
    File.write(source, "x = 1\n")
    File.write(spec, '')
    config = MutationTester::Configuration.new
    config.fail_fast = fail_fast
    core = MutationTester::Core.new(source, spec, config)
    core.instance_variable_set(:@results, results)
    core.instance_variable_set(:@mutations, Array.new(total_mutations) { {} })
    core
  end

  it 'is true when fail-fast stopped the run before every mutation was processed' do
    core = core_with(fail_fast: true, results: [{ status: :killed }, { status: :survived }], total_mutations: 3)
    expect(core.interrupted?).to be true
  end

  it 'is false when the first surviving mutant was the last mutation of a complete run' do
    core = core_with(fail_fast: true, results: [{ status: :killed }, { status: :survived }], total_mutations: 2)
    expect(core.interrupted?).to be false
  end

  it 'is false without fail-fast even when a mutant survived' do
    core = core_with(fail_fast: false, results: [{ status: :survived }], total_mutations: 3)
    expect(core.interrupted?).to be false
  end

  it 'still reports the fail-fast stop for a complete run so a batch does not continue past a survivor' do
    core = core_with(fail_fast: true, results: [{ status: :killed }, { status: :survived }], total_mutations: 2)

    expect(core.stopped_on_survivor?).to be true
    expect(core.interrupted?).to be false
  end

  it 'reports no fail-fast stop when every mutant of a complete run was killed' do
    core = core_with(fail_fast: true, results: [{ status: :killed }], total_mutations: 1)

    expect(core.stopped_on_survivor?).to be false
  end
end

RSpec.describe 'MutationTester::Core#run_mutations progress line shutdown' do
  def core_with_failing_runner(io, error)
    dir = Dir.mktmpdir
    source = File.join(dir, 'src.rb')
    spec = File.join(dir, 'src_spec.rb')
    File.write(source, "x = 1\n")
    File.write(spec, '')
    config = MutationTester::Configuration.new
    config.show_progress = true
    core = MutationTester::Core.new(source, spec, config)
    core.instance_variable_set(:@mutations, [{}, {}])
    runner = instance_double(MutationTester::MutationRunner)
    allow(runner).to receive(:run).and_raise(error)
    allow(core).to receive(:mutation_runner).and_return(runner)
    allow(MutationTester::ProgressDisplay).to receive(:new).and_wrap_original do |original, total, cfg|
      original.call(total, cfg, output_stream: io)
    end
    core
  end

  it 'stops the spinner thread and claims no completion when the run is interrupted' do
    io = StringIO.new
    core = core_with_failing_runner(io, Interrupt)
    threads_before = Thread.list

    expect { capture_stdout { core.send(:run_mutations) } }.to raise_error(Interrupt)

    expect(Thread.list - threads_before).to be_empty
    expect(io.string).not_to include('Completed in')
    expect(io.string).to end_with("\r")
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = original
  end
end
