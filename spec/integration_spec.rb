require 'spec_helper'
require 'fileutils'
require 'tmpdir'
require 'stringio'
require_relative 'support/timeout_binary_env'

RSpec.describe 'Integration' do
  let(:tmp_dir) { Dir.mktmpdir }
  let(:project_dir) { File.join(tmp_dir, 'test_project') }
  let(:lib_dir) { File.join(project_dir, 'lib') }
  let(:spec_dir) { File.join(project_dir, 'spec') }

  before do
    FileUtils.mkdir_p(lib_dir)
    FileUtils.mkdir_p(spec_dir)
    FileUtils.touch(File.join(project_dir, 'Gemfile'))
  end

  after do
    FileUtils.remove_entry(tmp_dir)
    MutationTester.reset_configuration!
  end

  it 'correctly identifies surviving mutations in uncovered code' do
    File.write(File.join(lib_dir, 'calculator.rb'), <<~RUBY)
      class Calculator
        def add(a, b)
          a + b
        end

        def unused(a)
          a + 1
        end
      end
    RUBY

    File.write(File.join(spec_dir, 'calculator_spec.rb'), <<~RUBY)
      require_relative '../lib/calculator'

      RSpec.describe Calculator do
        it 'adds two numbers' do
          expect(Calculator.new.add(1, 2)).to eq(3)
        end
      end
    RUBY

    Dir.chdir(project_dir) do
      require 'mutation_tester'

      MutationTester.configure do |config|
        config.parallel_processes = 1
        config.output_dir = 'mutation_reports'
        config.verbose = false
      end

      allow($stdout).to receive(:puts)
      allow($stdout).to receive(:print)

      source_file = File.join(lib_dir, 'calculator.rb')
      spec_file = File.join(spec_dir, 'calculator_spec.rb')

      runner = MutationTester::Core.new(source_file, spec_file)
      runner.run

      results = runner.results

      add_mutations = results.select { |r| r[:line] == 3 }
      expect(add_mutations).not_to be_empty
      expect(add_mutations.all? { |r| r[:killed] }).to be true

      unused_mutations = results.select { |r| r[:line] == 7 }
      expect(unused_mutations).not_to be_empty
      expect(unused_mutations.all? { |r| !r[:killed] }).to be true

      expect(runner.mutation_score).to be < 100.0
    end
  end

  it 'kills covered ** / ||= mutants and lets uncovered ones survive' do
    File.write(File.join(lib_dir, 'powers.rb'), <<~RUBY)
      class Powers
        def square(n)
          n ** 2
        end

        def memo
          @memo ||= 7
        end

        def uncovered_square(n)
          n ** 2
        end

        def uncovered_memo
          @uncovered ||= 7
        end
      end
    RUBY

    File.write(File.join(spec_dir, 'powers_spec.rb'), <<~RUBY)
      require_relative '../lib/powers'

      RSpec.describe Powers do
        it('squares via **') { expect(Powers.new.square(3)).to eq(9) }
        it('memoizes via ||=') { expect(Powers.new.memo).to eq(7) }
      end
    RUBY

    Dir.chdir(project_dir) do
      require 'mutation_tester'

      MutationTester.configure do |config|
        config.parallel_processes = 1
        config.output_dir = 'mutation_reports'
        config.verbose = false
      end

      allow($stdout).to receive(:puts)
      allow($stdout).to receive(:print)

      source_file = File.join(lib_dir, 'powers.rb')
      spec_file = File.join(spec_dir, 'powers_spec.rb')

      runner = MutationTester::Core.new(source_file, spec_file)
      runner.run
      results = runner.results

      covered_power = results.select { |r| r[:line] == 3 && r[:original] == '**' }
      expect(covered_power.map { |r| r[:mutated] }).to match_array(%w[* +])
      expect(covered_power.all? { |r| r[:killed] }).to be(true)

      covered_orasgn = results.find { |r| r[:line] == 7 && r[:original] == '||=' }
      expect(covered_orasgn).not_to be_nil
      expect(covered_orasgn[:mutated]).to eq('&&=')
      expect(covered_orasgn[:killed]).to be(true)

      uncovered_power = results.select { |r| r[:line] == 11 && r[:original] == '**' }
      expect(uncovered_power).not_to be_empty
      expect(uncovered_power.map { |r| r[:status] }).to all(eq(:survived))

      uncovered_orasgn = results.find { |r| r[:line] == 15 && r[:original] == '||=' }
      expect(uncovered_orasgn).not_to be_nil
      expect(uncovered_orasgn[:killed]).to be(false)
      expect(uncovered_orasgn[:status]).to eq(:survived)
    end
  end

  it 'surfaces a surviving uniq-removal mutant for a spec without duplicates and kills it with a duplicate-covering spec' do
    File.write(File.join(lib_dir, 'basket.rb'), <<~RUBY)
      class Basket
        PRICES = { 1 => 10, 2 => 20 }.freeze

        def total_of(item_ids)
          item_ids.uniq.sum { |id| PRICES.fetch(id) }
        end
      end
    RUBY

    File.write(File.join(spec_dir, 'basket_no_duplicates_spec.rb'), <<~RUBY)
      require_relative '../lib/basket'

      RSpec.describe Basket do
        it 'sums prices of distinct items' do
          expect(Basket.new.total_of([1, 2])).to eq(30)
        end
      end
    RUBY

    File.write(File.join(spec_dir, 'basket_with_duplicates_spec.rb'), <<~RUBY)
      require_relative '../lib/basket'

      RSpec.describe Basket do
        it 'counts each duplicate item id only once' do
          expect(Basket.new.total_of([1, 1, 2])).to eq(30)
        end
      end
    RUBY

    Dir.chdir(project_dir) do
      require 'mutation_tester'

      MutationTester.configure do |config|
        config.parallel_processes = 1
        config.output_dir = 'mutation_reports'
        config.verbose = false
        config.mutation_types.each_key do |type|
          config.mutation_types[type] = type == :call_removal
        end
      end

      allow($stdout).to receive(:puts)
      allow($stdout).to receive(:print)

      source_file = File.join(lib_dir, 'basket.rb')

      gap_runner = MutationTester::Core.new(source_file, File.join(spec_dir, 'basket_no_duplicates_spec.rb'))
      gap_runner.run
      surviving = gap_runner.results.find { |r| r[:type] == :call_removal && r[:original] == 'item_ids.uniq' }
      expect(surviving).not_to be_nil
      expect(surviving[:mutated]).to eq('item_ids')
      expect(surviving[:status]).to eq(:survived)

      covering_runner = MutationTester::Core.new(source_file, File.join(spec_dir, 'basket_with_duplicates_spec.rb'))
      covering_runner.run
      killed = covering_runner.results.find { |r| r[:type] == :call_removal && r[:original] == 'item_ids.uniq' }
      expect(killed).not_to be_nil
      expect(killed[:status]).to eq(:killed)
    end
  end

  it 'surfaces a surviving flag-operand removal for a spec without the flag path and kills it with a flag-covering spec' do
    File.write(File.join(lib_dir, 'shipping.rb'), <<~RUBY)
      class Shipping
        FREE_SHIPPING_ABOVE = 100

        def initialize(vip)
          @vip = vip
        end

        def cost(amount)
          return 0 if @vip || amount >= FREE_SHIPPING_ABOVE

          10
        end
      end
    RUBY

    File.write(File.join(spec_dir, 'shipping_no_vip_spec.rb'), <<~RUBY)
      require_relative '../lib/shipping'

      RSpec.describe Shipping do
        it 'ships large orders for free' do
          expect(Shipping.new(false).cost(150)).to eq(0)
        end

        it 'charges small orders' do
          expect(Shipping.new(false).cost(50)).to eq(10)
        end
      end
    RUBY

    File.write(File.join(spec_dir, 'shipping_with_vip_spec.rb'), <<~RUBY)
      require_relative '../lib/shipping'

      RSpec.describe Shipping do
        it 'ships large orders for free' do
          expect(Shipping.new(false).cost(150)).to eq(0)
        end

        it 'charges small orders' do
          expect(Shipping.new(false).cost(50)).to eq(10)
        end

        it 'ships small VIP orders for free' do
          expect(Shipping.new(true).cost(50)).to eq(0)
        end
      end
    RUBY

    Dir.chdir(project_dir) do
      require 'mutation_tester'

      MutationTester.configure do |config|
        config.parallel_processes = 1
        config.output_dir = 'mutation_reports'
        config.verbose = false
        config.mutation_types.each_key do |type|
          config.mutation_types[type] = type == :logical
        end
      end

      allow($stdout).to receive(:puts)
      allow($stdout).to receive(:print)

      source_file = File.join(lib_dir, 'shipping.rb')
      removal_description = 'Remove operand @vip from ||'

      gap_runner = MutationTester::Core.new(source_file, File.join(spec_dir, 'shipping_no_vip_spec.rb'))
      gap_runner.run
      surviving = gap_runner.results.find { |r| r[:description] == removal_description }
      expect(surviving).not_to be_nil
      expect(surviving[:type]).to eq(:logical)
      expect(surviving[:mutated]).to eq('amount >= FREE_SHIPPING_ABOVE')
      expect(surviving[:status]).to eq(:survived)

      covering_runner = MutationTester::Core.new(source_file, File.join(spec_dir, 'shipping_with_vip_spec.rb'))
      covering_runner.run
      killed = covering_runner.results.find { |r| r[:description] == removal_description }
      expect(killed).not_to be_nil
      expect(killed[:status]).to eq(:killed)
    end
  end

  it 'surfaces surviving argument mutants for a class-only raise spec and an unasserted constructor argument, and kills them with a covering spec' do
    File.write(File.join(lib_dir, 'reporting.rb'), <<~RUBY)
      class Reporting
        class Result
          def initialize(status, label)
            @status = status
            @label = label
          end

          def status
            @status
          end

          def label
            @label
          end
        end

        def parse!(value)
          raise ArgumentError, 'value required' if value.nil?

          Result.new(:ok, format_label(value))
        end

        def format_label(value)
          "value: " + value.to_s
        end
      end
    RUBY

    File.write(File.join(spec_dir, 'reporting_gap_spec.rb'), <<~RUBY)
      require_relative '../lib/reporting'

      RSpec.describe Reporting do
        it 'raises on nil input' do
          expect { Reporting.new.parse!(nil) }.to raise_error(ArgumentError)
        end

        it 'builds an ok result' do
          expect(Reporting.new.parse!(1).status).to eq(:ok)
        end
      end
    RUBY

    File.write(File.join(spec_dir, 'reporting_covering_spec.rb'), <<~RUBY)
      require_relative '../lib/reporting'

      RSpec.describe Reporting do
        it 'raises on nil input with a message' do
          expect { Reporting.new.parse!(nil) }.to raise_error(ArgumentError, /value required/)
        end

        it 'builds an ok result with a label' do
          result = Reporting.new.parse!(1)
          expect(result.status).to eq(:ok)
          expect(result.label).to eq('value: 1')
        end
      end
    RUBY

    Dir.chdir(project_dir) do
      require 'mutation_tester'

      MutationTester.configure do |config|
        config.parallel_processes = 1
        config.output_dir = 'mutation_reports'
        config.verbose = false
        config.mutation_types.each_key do |type|
          config.mutation_types[type] = type == :argument
        end
      end

      allow($stdout).to receive(:puts)
      allow($stdout).to receive(:print)

      source_file = File.join(lib_dir, 'reporting.rb')
      removal_description = 'Remove last argument from raise'
      substitution_description = 'Replace argument format_label(value) with nil'

      gap_runner = MutationTester::Core.new(source_file, File.join(spec_dir, 'reporting_gap_spec.rb'))
      gap_runner.run

      surviving_removal = gap_runner.results.find { |r| r[:description] == removal_description }
      expect(surviving_removal).not_to be_nil
      expect(surviving_removal[:type]).to eq(:argument)
      expect(surviving_removal[:mutated]).to eq('raise ArgumentError')
      expect(surviving_removal[:status]).to eq(:survived)

      surviving_substitution = gap_runner.results.find { |r| r[:description] == substitution_description }
      expect(surviving_substitution).not_to be_nil
      expect(surviving_substitution[:type]).to eq(:argument)
      expect(surviving_substitution[:mutated]).to eq('Result.new(:ok, nil)')
      expect(surviving_substitution[:status]).to eq(:survived)

      covering_runner = MutationTester::Core.new(source_file, File.join(spec_dir, 'reporting_covering_spec.rb'))
      covering_runner.run

      killed_removal = covering_runner.results.find { |r| r[:description] == removal_description }
      expect(killed_removal[:status]).to eq(:killed)

      killed_substitution = covering_runner.results.find { |r| r[:description] == substitution_description }
      expect(killed_substitution[:status]).to eq(:killed)
    end
  end

  it 'kills a tested negated condition and survives an untested one without erroring' do
    File.write(File.join(lib_dir, 'grader.rb'), <<~RUBY)
      class Grader
        def label(n)
          if n > 0
            "positive"
          else
            "non-positive"
          end
        end

        def annotate(n)
          note = "n"
          if n > 0
            note += "!"
          end
          note
        end
      end
    RUBY

    File.write(File.join(spec_dir, 'grader_spec.rb'), <<~RUBY)
      require_relative '../lib/grader'

      RSpec.describe Grader do
        it 'labels positive numbers' do
          expect(Grader.new.label(5)).to eq("positive")
        end

        it 'annotates without asserting the guarded suffix' do
          # Exercises the `if n > 0` line in annotate so it is covered, but only
          # asserts the prefix, so negating that guard is not observable here.
          expect(Grader.new.annotate(5)).to include("n")
        end
      end
    RUBY

    Dir.chdir(project_dir) do
      require 'mutation_tester'

      MutationTester.configure do |config|
        config.parallel_processes = 1
        config.output_dir = 'mutation_reports'
        config.verbose = false
      end

      allow($stdout).to receive(:puts)
      allow($stdout).to receive(:print)

      source_file = File.join(lib_dir, 'grader.rb')
      spec_file = File.join(spec_dir, 'grader_spec.rb')

      runner = MutationTester::Core.new(source_file, spec_file)
      runner.run

      conditional = runner.results.select { |r| r[:type] == :conditional }

      expect(conditional.size).to eq(2)

      expect(conditional.map { |r| r[:status] }).not_to include(:error)

      labelled = conditional.find { |r| r[:line] == 3 }
      annotated = conditional.find { |r| r[:line] == 12 }

      expect(labelled[:killed]).to be true

      expect(annotated[:killed]).to be false
      expect(annotated[:status]).to eq(:survived)
    end
  end

  it 'kills a loop-negation mutant by timeout (infinite) and by assertion (zero iterations)' do
    File.write(File.join(lib_dir, 'looper.rb'), <<~RUBY)
      class Looper
        def sum_down(n)
          total = 0
          while n > 0
            total += n
            n -= 1
          end
          total
        end

        def count_up(n)
          i = 0
          until i == n
            i += 1
          end
          i
        end
      end
    RUBY

    File.write(File.join(spec_dir, 'looper_spec.rb'), <<~RUBY)
      require_relative '../lib/looper'

      RSpec.describe Looper do
        it('sums an empty countdown to zero') { expect(Looper.new.sum_down(0)).to eq(0) }
        it('counts up to n') { expect(Looper.new.count_up(3)).to eq(3) }
      end
    RUBY

    Dir.chdir(project_dir) do
      require 'mutation_tester'

      MutationTester.configure do |config|
        config.parallel_processes = 1
        config.output_dir = 'mutation_reports'
        config.verbose = false
        config.timeout = 2
      end

      allow($stdout).to receive(:puts)
      allow($stdout).to receive(:print)

      source_file = File.join(lib_dir, 'looper.rb')
      spec_file = File.join(spec_dir, 'looper_spec.rb')

      runner = MutationTester::Core.new(source_file, spec_file)
      runner.run

      conditional = runner.results.select { |r| r[:type] == :conditional }
      expect(conditional.map { |r| r[:original] }).to match_array(['n > 0', 'i == n'])

      while_mutant = conditional.find { |r| r[:original] == 'n > 0' }
      expect(while_mutant[:mutated]).to eq('!(n > 0)')
      expect(while_mutant[:status]).to eq(:timeout)
      expect(while_mutant[:killed]).to be(true)

      until_mutant = conditional.find { |r| r[:original] == 'i == n' }
      expect(until_mutant[:mutated]).to eq('!(i == n)')
      expect(until_mutant[:status]).to eq(:killed)
      expect(until_mutant[:killed]).to be(true)
    end
  end

  it 'excludes an annotated equivalent-mutant line end to end and reports it' do
    File.write(File.join(lib_dir, 'math_util.rb'), <<~RUBY)
      class MathUtil
        def maximum(a, b)
          a > b ? a : b # mutation_tester:disable
        end

        def add(a, b)
          a + b
        end
      end
    RUBY

    File.write(File.join(spec_dir, 'math_util_spec.rb'), <<~RUBY)
      require_relative '../lib/math_util'

      RSpec.describe MathUtil do
        it('returns the larger argument') { expect(MathUtil.new.maximum(2, 1)).to eq(2) }
        it('returns the other larger argument') { expect(MathUtil.new.maximum(1, 2)).to eq(2) }
        it('adds two numbers') { expect(MathUtil.new.add(1, 2)).to eq(3) }
      end
    RUBY

    Dir.chdir(project_dir) do
      require 'mutation_tester'

      MutationTester.configure do |config|
        config.parallel_processes = 1
        config.output_dir = 'mutation_reports'
        config.verbose = false
      end

      source_file = File.join(lib_dir, 'math_util.rb')
      spec_file = File.join(spec_dir, 'math_util_spec.rb')

      runner = MutationTester::Core.new(source_file, spec_file)

      captured = StringIO.new
      original_stdout = $stdout
      $stdout = captured
      begin
        runner.run
      ensure
        $stdout = original_stdout
      end

      results = runner.results

      expect(results.select { |r| r[:line] == 3 }).to be_empty

      add_mutations = results.select { |r| r[:line] == 7 }
      expect(add_mutations).not_to be_empty
      expect(add_mutations.all? { |r| r[:killed] }).to be(true)

      expect(runner.mutation_score).to eq(100.0)

      expect(captured.string).to include('Excluded: 1 line(s) (mutation_tester:disable)')
    end
  end

  it 'kills a case/when branch deletion when the branch is tested and survives it when it is not' do
    File.write(File.join(lib_dir, 'classifier.rb'), <<~RUBY)
      class Classifier
        def label(n)
          case n
          when 1 then "one"
          when 2 then "two"
          else "many"
          end
        end
      end
    RUBY

    require 'mutation_tester'

    run_with_spec = lambda do |spec_body|
      File.write(File.join(spec_dir, 'classifier_spec.rb'), <<~RUBY)
        require_relative '../lib/classifier'

        RSpec.describe Classifier do
        #{spec_body}
        end
      RUBY

      Dir.chdir(project_dir) do
        MutationTester.configure do |config|
          config.parallel_processes = 1
          config.output_dir = 'mutation_reports'
          config.verbose = false
        end

        allow($stdout).to receive(:puts)
        allow($stdout).to receive(:print)

        runner = MutationTester::Core.new(
          File.join(lib_dir, 'classifier.rb'),
          File.join(spec_dir, 'classifier_spec.rb')
        )
        runner.run
        runner.results.select { |r| r[:description] == 'Remove when branch' }
      end
    end

    full = run_with_spec.call(<<~SPEC)
      it { expect(Classifier.new.label(1)).to eq("one") }
        it { expect(Classifier.new.label(2)).to eq("two") }
        it { expect(Classifier.new.label(9)).to eq("many") }
    SPEC

    expect(full.map { |r| r[:line] }).to match_array([4, 5])
    expect(full.all? { |r| r[:status] == :killed }).to be(true)

    partial = run_with_spec.call(<<~SPEC)
      it { expect(Classifier.new.label(2)).to eq("two") }
        it { expect(Classifier.new.label(9)).to eq("many") }
    SPEC

    when1 = partial.find { |r| r[:line] == 4 }
    when2 = partial.find { |r| r[:line] == 5 }

    expect(when1[:status]).to eq(:survived)
    expect(when1[:killed]).to be(false)
    expect(when2[:status]).to eq(:killed)
  end

  it 'surfaces a surviving nil-injection mutant on a fluent self return for a side-effect-only spec and kills it with a return-value spec' do
    File.write(File.join(lib_dir, 'ledger.rb'), <<~RUBY)
      class Ledger
        def initialize
          @entries = []
        end

        def register!(item)
          @entries.push(item)
          self
        end

        attr_reader :entries
      end
    RUBY

    require 'mutation_tester'

    run_with_spec = lambda do |spec_body|
      File.write(File.join(spec_dir, 'ledger_spec.rb'), <<~RUBY)
        require_relative '../lib/ledger'

        RSpec.describe Ledger do
        #{spec_body}
        end
      RUBY

      Dir.chdir(project_dir) do
        MutationTester.configure do |config|
          config.parallel_processes = 1
          config.output_dir = 'mutation_reports'
          config.verbose = false
        end

        allow($stdout).to receive(:puts)
        allow($stdout).to receive(:print)

        runner = MutationTester::Core.new(
          File.join(lib_dir, 'ledger.rb'),
          File.join(spec_dir, 'ledger_spec.rb')
        )
        runner.run
        runner.results.find { |r| r[:type] == :nil_injection && r[:original] == 'self' }
      end
    end

    side_effect_only = run_with_spec.call(<<~SPEC)
      it 'stores the registered entry' do
          ledger = Ledger.new
          ledger.register!(:sale)
          expect(ledger.entries).to eq([:sale])
        end
    SPEC

    expect(side_effect_only[:line]).to eq(8)
    expect(side_effect_only[:status]).to eq(:survived)
    expect(side_effect_only[:killed]).to be(false)

    with_return_assertion = run_with_spec.call(<<~SPEC)
      it 'returns itself for chaining' do
          ledger = Ledger.new
          expect(ledger.register!(:sale)).to be(ledger)
        end
    SPEC

    expect(with_return_assertion[:status]).to eq(:killed)
  end

  it 'surfaces surviving default-value mutants when every test passes the optional argument and kills them with a call omitting it' do
    File.write(File.join(lib_dir, 'greeter.rb'), <<~RUBY)
      class Greeter
        def greet(name, punct = '!')
          name + punct
        end
      end
    RUBY

    require 'mutation_tester'

    run_with_spec = lambda do |spec_body|
      File.write(File.join(spec_dir, 'greeter_spec.rb'), <<~RUBY)
        require_relative '../lib/greeter'

        RSpec.describe Greeter do
        #{spec_body}
        end
      RUBY

      Dir.chdir(project_dir) do
        MutationTester.configure do |config|
          config.parallel_processes = 1
          config.output_dir = 'mutation_reports'
          config.verbose = false
        end

        allow($stdout).to receive(:puts)
        allow($stdout).to receive(:print)

        runner = MutationTester::Core.new(
          File.join(lib_dir, 'greeter.rb'),
          File.join(spec_dir, 'greeter_spec.rb')
        )
        runner.run
        runner.results.select { |r| r[:type] == :argument && r[:description].include?('default value') }
      end
    end

    always_passing_punct = run_with_spec.call(<<~SPEC)
      it { expect(Greeter.new.greet('hi', '?')).to eq('hi?') }
    SPEC

    expect(always_passing_punct.map { |r| r[:description] }).to match_array(
      ['Remove default value of punct', 'Replace default value of punct with nil']
    )
    expect(always_passing_punct.map { |r| r[:status] }).to all(eq(:survived))

    omitting_punct = run_with_spec.call(<<~SPEC)
      it { expect(Greeter.new.greet('hi', '?')).to eq('hi?') }
        it { expect(Greeter.new.greet('hi')).to eq('hi!') }
    SPEC

    expect(omitting_punct.map { |r| r[:status] }).to all(eq(:killed))
  end

  it 'runs correctly in parallel' do
    File.write(File.join(lib_dir, 'calculator.rb'), <<~RUBY)
      class Calculator
        def add(a, b)
          a + b
        end
      end
    RUBY

    File.write(File.join(spec_dir, 'calculator_spec.rb'), <<~RUBY)
      require_relative '../lib/calculator'

      RSpec.describe Calculator do
        it 'adds two numbers' do
          expect(Calculator.new.add(1, 2)).to eq(3)
        end
      end
    RUBY

    Dir.chdir(project_dir) do
      require 'mutation_tester'

      MutationTester.configure do |config|
        config.parallel_processes = 2
        config.output_dir = 'mutation_reports'
        config.verbose = false
      end

      allow($stdout).to receive(:puts)
      allow($stdout).to receive(:print)

      source_file = File.join(lib_dir, 'calculator.rb')
      spec_file = File.join(spec_dir, 'calculator_spec.rb')

      runner = MutationTester::Core.new(source_file, spec_file)
      runner.run

      results = runner.results
      expect(results).not_to be_empty
      expect(results.all? { |r| r[:killed] }).to be true
    end
  end

  it 'produces an identical killed/survived set in parallel and serial when the spec loads source via spec_helper' do
    File.write(File.join(lib_dir, 'thing.rb'), <<~RUBY)
      class Thing
        def add(a, b)
          a + b
        end

        def unused(a)
          a + 1
        end
      end
    RUBY

    File.write(File.join(spec_dir, 'spec_helper.rb'), <<~RUBY)
      require_relative '../lib/thing'
    RUBY

    File.write(File.join(spec_dir, 'thing_spec.rb'), <<~RUBY)
      require_relative 'spec_helper'

      RSpec.describe Thing do
        it 'adds two numbers' do
          expect(Thing.new.add(1, 2)).to eq(3)
        end
      end
    RUBY

    require 'mutation_tester'

    source_file = File.join(lib_dir, 'thing.rb')
    spec_file = File.join(spec_dir, 'thing_spec.rb')
    original = File.read(source_file)

    ast = Parser::CurrentRuby.parse(original)
    mutations = MutationTester::Mutator.new(source_file, MutationTester::Configuration.new).generate_mutations(ast)
    expect(mutations).not_to be_empty

    run_in_mode = lambda do |processes|
      config = MutationTester::Configuration.new
      config.runner = :fork
      config.parallel_processes = processes
      runner = MutationTester::MutationRunner.new(source_file, spec_file, original, config)
      results = Dir.chdir(project_dir) { runner.run(mutations) }
      results.to_h { |r| [r[:id], r[:killed]] }
    end

    serial = run_in_mode.call(1)
    parallel = run_in_mode.call(2)

    expect(parallel).to eq(serial)
    expect(parallel.values).to include(true)
  end

  describe 'guaranteed mutant timeout without the external `timeout` binary' do
    around do |example|
      TimeoutBinaryEnv.without_timeout_binary { example.run }
    end

    def process_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    end

    it 'terminates an infinite-loop mutant mid-run and reports it as a timeout' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, 'lib'))
        FileUtils.mkdir_p(File.join(dir, 'spec'))
        source = File.join(dir, 'lib', 'calculator.rb')
        spec = File.join(dir, 'spec', 'calculator_spec.rb')

        File.write(source, <<~RUBY)
          class Calculator
            def add(a, b)
              a + b
            end
          end
        RUBY
        File.write(spec, <<~RUBY)
          require_relative '../lib/calculator'

          RSpec.describe Calculator do
            it 'adds two numbers' do
              expect(Calculator.new.add(1, 2)).to eq(3)
            end
          end
        RUBY

        config = MutationTester::Configuration.new
        config.parallel_processes = 1
        config.timeout = 2
        config.runner = :spawn

        runner = MutationTester::MutationRunner.new(source, spec, File.read(source), config)

        mutations = [
          {
            id: 1,
            type: :arithmetic,
            line: 3,
            code: "class Calculator\n  def add(a, b)\n    a - b\n  end\nend\n",
            description: 'a + b -> a - b'
          },
          {
            id: 2,
            type: :infinite,
            line: 1,
            code: "while true; end\n",
            description: 'infinite loop'
          }
        ]

        spawned_pids = []
        allow(Process).to receive(:spawn).and_wrap_original do |original, *args|
          pid = original.call(*args)
          spawned_pids << pid
          pid
        end

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        results = Dir.chdir(dir) { runner.run(mutations) }
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        expect(elapsed).to be < (config.timeout + 5)

        hung = results.find { |r| r[:id] == 2 }
        expect(hung[:timeout]).to be(true)
        expect(hung[:killed]).to be(true)

        normal = results.find { |r| r[:id] == 1 }
        expect(normal[:timeout]).to be(false)
        expect(normal[:killed]).to be(true)

        expect(spawned_pids).not_to be_empty
        spawned_pids.each { |pid| expect(process_alive?(pid)).to be(false) }
      end
    end
  end
end

RSpec.describe 'MutationTester::Core baseline without a shell' do
  HOSTILE_SPEC_NAME = 'a b;c_spec.rb'

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  def write_project(dir, spec_name:, expectation:)
    FileUtils.touch(File.join(dir, 'Gemfile'))
    source = File.join(dir, 'calc.rb')
    spec = File.join(dir, spec_name)
    File.write(source, <<~RUBY)
      class Calc
        def add(a, b)
          a + b
        end
      end
    RUBY
    File.write(spec, <<~RUBY)
      require_relative 'calc'

      RSpec.describe 'Calc' do
        it('adds') { expect(Calc.new.add(1, 2)).to #{expectation} }
      end
    RUBY
    [source, spec]
  end

  it 'passes the baseline for a hostile spec path and reaches the mutation phase' do
    Dir.mktmpdir do |dir|
      source, spec = write_project(dir, spec_name: HOSTILE_SPEC_NAME, expectation: 'eq(3)')

      config = MutationTester::Configuration.new
      config.verbose = false
      core = MutationTester::Core.new(source, spec, config)
      allow(core).to receive(:puts)

      reached_mutation_phase = false
      allow(core).to receive(:run_mutations) { reached_mutation_phase = true }
      allow(core).to receive(:generate_reports)

      core.run

      expect(core.mutations).not_to be_empty
      expect(reached_mutation_phase).to be(true)
    end
  end

  it 'prints the exact failing command when the baseline fails' do
    Dir.mktmpdir do |dir|
      source, spec = write_project(dir, spec_name: 'calc_spec.rb', expectation: 'eq(999)')

      config = MutationTester::Configuration.new
      config.verbose = false
      core = MutationTester::Core.new(source, spec, config)
      expected_command = core.send(:test_command).command

      returned = nil
      output = capture_stdout { returned = core.send(:run_original_tests) }

      expect(returned).to be false
      expect(output).to include('Debug: The following command failed:')
      expect(output).to include(expected_command)
    end
  end

  it 'replays the captured test output when the baseline fails' do
    Dir.mktmpdir do |dir|
      source, spec = write_project(dir, spec_name: 'calc_spec.rb', expectation: 'eq(999)')

      config = MutationTester::Configuration.new
      config.verbose = false
      core = MutationTester::Core.new(source, spec, config)

      returned = nil
      output = capture_stdout { returned = core.send(:run_original_tests) }

      expect(returned).to be false
      expect(output).to include('999')
      expect(output).to include('1 example, 1 failure')
    end
  end
end

RSpec.describe 'MutationTester::Core baseline hard timeout' do
  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  it 'kills a hanging baseline after baseline_timeout and makes Core#run return false' do
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'calculator.rb')
      spec = File.join(dir, 'calculator_test.rb')
      File.write(source, <<~RUBY)
        class Calculator
          def add(a, b)
            a + b
          end
        end
      RUBY
      File.write(spec, "while true; end\n")

      config = MutationTester::Configuration.new
      config.verbose = false
      config.baseline_timeout = 2

      core = MutationTester::Core.new(source, spec, config)

      spawned_pids = []
      allow(Process).to receive(:spawn).and_wrap_original do |original, *args|
        pid = original.call(*args)
        spawned_pids << pid
        pid
      end

      returned = nil
      elapsed = nil
      output = capture_stdout do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        returned = core.run
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      end

      expect(returned).to be false
      expect(core.mutations).to be_empty
      expect(elapsed).to be < (config.baseline_timeout + 5)

      expect(output).to include('baseline deadline')

      expect(spawned_pids).not_to be_empty
      spawned_pids.each { |pid| expect(process_alive?(pid)).to be(false) }
    end
  end
end

RSpec.describe 'MutationTester::Core shadow baseline sanity check' do
  def silence_stdout
    allow($stdout).to receive(:puts)
    allow($stdout).to receive(:print)
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  def write_covered_project(dir)
    FileUtils.mkdir_p(File.join(dir, 'lib'))
    FileUtils.mkdir_p(File.join(dir, 'spec'))
    FileUtils.touch(File.join(dir, 'Gemfile'))
    File.write(File.join(dir, 'lib', 'calculator.rb'), <<~RUBY)
      class Calculator
        def add(a, b)
          a + b
        end
      end
    RUBY
    File.write(File.join(dir, 'spec', 'calculator_spec.rb'), <<~RUBY)
      require_relative '../lib/calculator'

      RSpec.describe Calculator do
        it('adds') { expect(Calculator.new.add(1, 2)).to eq(3) }
      end
    RUBY
    [File.join(dir, 'lib', 'calculator.rb'), File.join(dir, 'spec', 'calculator_spec.rb')]
  end

  def write_mixed_project(dir)
    FileUtils.mkdir_p(File.join(dir, 'lib'))
    FileUtils.mkdir_p(File.join(dir, 'spec'))
    FileUtils.touch(File.join(dir, 'Gemfile'))
    File.write(File.join(dir, 'lib', 'calculator.rb'), <<~RUBY)
      class Calculator
        def add(a, b)
          a + b
        end

        def unused(a)
          a + 1
        end
      end
    RUBY
    File.write(File.join(dir, 'spec', 'calculator_spec.rb'), <<~RUBY)
      require_relative '../lib/calculator'

      RSpec.describe Calculator do
        it('adds') { expect(Calculator.new.add(1, 2)).to eq(3) }
      end
    RUBY
    [File.join(dir, 'lib', 'calculator.rb'), File.join(dir, 'spec', 'calculator_spec.rb')]
  end

  def write_shadow_breaking_project(dir)
    FileUtils.mkdir_p(File.join(dir, 'lib'))
    FileUtils.mkdir_p(File.join(dir, 'spec'))
    FileUtils.mkdir_p(File.join(dir, 'tmp'))
    FileUtils.touch(File.join(dir, 'Gemfile'))
    File.write(File.join(dir, 'lib', 'calculator.rb'), <<~RUBY)
      class Calculator
        def add(a, b)
          a + b
        end
      end
    RUBY
    File.write(File.join(dir, 'tmp', 'shared.rb'), "SHADOW_ONLY = true\n")
    File.write(File.join(dir, 'spec', 'calculator_spec.rb'), <<~RUBY)
      require_relative '../lib/calculator'
      require_relative '../tmp/shared'

      RSpec.describe Calculator do
        it('adds') { expect(SHADOW_ONLY && Calculator.new.add(1, 2) == 3).to be(true) }
      end
    RUBY
    [File.join(dir, 'lib', 'calculator.rb'), File.join(dir, 'spec', 'calculator_spec.rb')]
  end

  def count_shadow_checks
    calls = 0
    allow_any_instance_of(MutationTester::MutationRunner)
      .to receive(:shadow_baseline_passes?).and_wrap_original do |original, *args|
      calls += 1
      original.call(*args)
    end
    -> { calls }
  end

  it 'runs exactly one unmutated shadow sanity check in parallel and then proceeds' do
    Dir.mktmpdir do |dir|
      source, spec = write_covered_project(dir)
      require 'mutation_tester'
      silence_stdout
      shadow_checks = count_shadow_checks

      config = MutationTester::Configuration.new
      config.runner = :fork
      config.parallel_processes = 2
      config.output_dir = 'mutation_reports'
      config.verbose = false

      core = MutationTester::Core.new(source, spec, config)
      returned = Dir.chdir(dir) { core.run }

      expect(shadow_checks.call).to eq(1)
      expect(returned).to be(true)
      expect(core.results).not_to be_empty
      expect(core.results.all? { |r| r[:killed] }).to be(true)
    end
  end

  it 'does not run the shadow sanity check in serial mode' do
    Dir.mktmpdir do |dir|
      source, spec = write_covered_project(dir)
      require 'mutation_tester'
      silence_stdout
      shadow_checks = count_shadow_checks

      config = MutationTester::Configuration.new
      config.parallel_processes = 1
      config.output_dir = 'mutation_reports'
      config.verbose = false

      core = MutationTester::Core.new(source, spec, config)
      Dir.chdir(dir) { core.run }

      expect(shadow_checks.call).to eq(0)
    end
  end

  it 'does not run the shadow sanity check when the in-memory runner is combined with parallel processes' do
    Dir.mktmpdir do |dir|
      source, spec = write_covered_project(dir)
      require 'mutation_tester'
      silence_stdout
      shadow_checks = count_shadow_checks

      config = MutationTester::Configuration.new
      config.parallel_processes = 2
      config.runner = :in_memory
      config.output_dir = 'mutation_reports'
      config.verbose = false

      core = MutationTester::Core.new(source, spec, config)
      returned = Dir.chdir(dir) { core.run }

      expect(shadow_checks.call).to eq(0)
      expect(returned).to be(true)
      expect(core.results).not_to be_empty
      expect(core.results.all? { |r| r[:killed] }).to be(true)
    end
  end

  it 'gives the same killed/survived results in parallel as serial when the shadow is healthy' do
    Dir.mktmpdir do |dir|
      source, spec = write_mixed_project(dir)
      require 'mutation_tester'
      silence_stdout

      run_mode = lambda do |processes|
        config = MutationTester::Configuration.new
        config.runner = :fork
        config.parallel_processes = processes
        config.output_dir = 'mutation_reports'
        config.verbose = false
        core = MutationTester::Core.new(source, spec, config)
        Dir.chdir(dir) { core.run }
        core.results.to_h { |r| [r[:id], r[:killed]] }
      end

      serial = run_mode.call(1)
      parallel = run_mode.call(2)

      expect(parallel).to eq(serial)
      expect(serial.values).to include(true, false)
    end
  end

  it 'aborts with Core#run == false and a clear message when the unmutated source fails in shadow' do
    Dir.mktmpdir do |dir|
      source, spec = write_shadow_breaking_project(dir)
      require 'mutation_tester'

      config = MutationTester::Configuration.new
      config.runner = :fork
      config.parallel_processes = 2
      config.output_dir = 'mutation_reports'
      config.verbose = false

      core = MutationTester::Core.new(source, spec, config)
      returned = nil
      output = capture_stdout { returned = Dir.chdir(dir) { core.run } }

      expect(returned).to be(false)
      expect(core.results).to be_empty
      expect(output).to match(/shadow/i)
      expect(output).to match(/unreliable/i)
    end
  end
end

RSpec.describe 'exe/mutation_test exit code reflects the threshold result' do
  ROOT = File.expand_path('..', __dir__)

  def cli_status(source, spec, chdir:)
    env = { 'BUNDLE_GEMFILE' => File.join(ROOT, 'Gemfile') }
    system(
      env,
      'bundle', 'exec', File.join(ROOT, 'exe', 'mutation_test'), source, spec,
      chdir: chdir, out: File::NULL, err: File::NULL
    )
    $?.exitstatus
  end

  it 'exits 1 when the score is below the default threshold' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'uncovered.rb'), <<~RUBY)
        class Uncovered
          def unused(a)
            a + 1
          end
        end
      RUBY
      File.write(File.join(dir, 'uncovered_spec.rb'), <<~RUBY)
        require_relative 'uncovered'

        RSpec.describe Uncovered do
          it('loads') { expect(Uncovered.new).to be_a(Uncovered) }
        end
      RUBY

      status = cli_status(
        File.join(dir, 'uncovered.rb'),
        File.join(dir, 'uncovered_spec.rb'),
        chdir: dir
      )
      expect(status).to eq(1)
    end
  end

  it 'exits 0 when the score meets the default threshold' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'covered.rb'), <<~RUBY)
        class Covered
          def add(a, b)
            a + b
          end
        end
      RUBY
      File.write(File.join(dir, 'covered_spec.rb'), <<~RUBY)
        require_relative 'covered'

        RSpec.describe Covered do
          it('adds') { expect(Covered.new.add(1, 2)).to eq(3) }
        end
      RUBY

      status = cli_status(
        File.join(dir, 'covered.rb'),
        File.join(dir, 'covered_spec.rb'),
        chdir: dir
      )
      expect(status).to eq(0)
    end
  end

  it 'exits non-zero when the source file has a syntax error' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'broken.rb'), "def broken(\n")
      File.write(File.join(dir, 'broken_spec.rb'), <<~RUBY)
        RSpec.describe 'standalone' do
          it('passes') { expect(1).to eq(1) }
        end
      RUBY

      status = cli_status(
        File.join(dir, 'broken.rb'),
        File.join(dir, 'broken_spec.rb'),
        chdir: dir
      )
      expect(status).not_to eq(0)
    end
  end
end

RSpec.describe 'exe/mutation_test run banner' do
  BANNER_ROOT = File.expand_path('..', __dir__)

  def cli_output(source, spec, chdir:)
    env = { 'BUNDLE_GEMFILE' => File.join(BANNER_ROOT, 'Gemfile') }
    IO.popen(
      env,
      ['bundle', 'exec', File.join(BANNER_ROOT, 'exe', 'mutation_test'), source, spec],
      'r',
      chdir: chdir, err: %i[child out]
    ) { |io| io.read }
  end

  it 'prints the run banner exactly once' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'covered.rb'), <<~RUBY)
        class Covered
          def add(a, b)
            a + b
          end
        end
      RUBY
      File.write(File.join(dir, 'covered_spec.rb'), <<~RUBY)
        require_relative 'covered'

        RSpec.describe Covered do
          it('adds') { expect(Covered.new.add(1, 2)).to eq(3) }
        end
      RUBY

      output = cli_output(
        File.join(dir, 'covered.rb'),
        File.join(dir, 'covered_spec.rb'),
        chdir: dir
      )

      expect(output.scan('🧬 MutationTester v').size).to eq(1)
    end
  end
end

RSpec.describe 'rake mutation:test_models runs a mutation run for each model' do
  RAKE_ROOT = File.expand_path('..', __dir__)

  def run_test_models(project_dir)
    runner = File.join(project_dir, 'run_task.rb')
    File.write(runner, <<~RUBY)
      require 'rake'
      require 'mutation_tester'
      self.extend(Rake::DSL)
      Rake::Task.define_task(:environment)
      load #{File.join(RAKE_ROOT, 'lib', 'tasks', 'mutation_tester.rake').inspect}
      Rake::Task['mutation:test_models'].invoke
    RUBY

    env = { 'BUNDLE_GEMFILE' => File.join(RAKE_ROOT, 'Gemfile') }
    output = IO.popen(
      env,
      ['bundle', 'exec', 'ruby', runner],
      'r',
      chdir: project_dir, err: %i[child out]
    ) { |io| io.read }
    [output, $?.exitstatus]
  end

  it 'processes every file even when the first is below threshold and exits non-zero if any missed' do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'app', 'models'))
      FileUtils.mkdir_p(File.join(dir, 'spec', 'models'))

      File.write(File.join(dir, 'app/models/a_model.rb'), <<~RUBY)
        class AModel
          def unused(x)
            x + 1
          end
        end
      RUBY
      File.write(File.join(dir, 'spec/models/a_model_spec.rb'), <<~RUBY)
        require_relative '../../app/models/a_model'

        RSpec.describe AModel do
          it('exists') { expect(AModel.new).to be_a(AModel) }
        end
      RUBY

      File.write(File.join(dir, 'app/models/b_model.rb'), <<~RUBY)
        class BModel
          def add(x, y)
            x + y
          end
        end
      RUBY
      File.write(File.join(dir, 'spec/models/b_model_spec.rb'), <<~RUBY)
        require_relative '../../app/models/b_model'

        RSpec.describe BModel do
          it('adds') { expect(BModel.new.add(1, 2)).to eq(3) }
        end
      RUBY

      output, status = run_test_models(dir)

      expect(output).to include('app/models/a_model.rb')
      expect(output).to include('app/models/b_model.rb')

      expect(status).not_to eq(0)
    end
  end
end
