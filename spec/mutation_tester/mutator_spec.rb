require 'spec_helper'
require 'tmpdir'

RSpec.describe MutationTester::Mutator, '(tables and switches)' do
  def build_mutator(source, config = MutationTester::Configuration.new)
    dir = Dir.mktmpdir
    path = File.join(dir, 'src.rb')
    File.write(path, source)
    MutationTester::Mutator.new(path, config)
  end

  def mutations_for(source, config = MutationTester::Configuration.new)
    mutator = build_mutator(source, config)
    ast = Parser::CurrentRuby.parse(source)
    mutator.generate_mutations(ast)
  end

  describe 'operator substitution tables' do
    MutationTester::Mutator::MUTATIONS[:arithmetic].each do |operator, replacements|
      it "generates exactly #{replacements.inspect} for arithmetic operator #{operator.inspect}" do
        source = "a #{operator} b\n"
        arithmetic = mutations_for(source).select { |m| m[:type] == :arithmetic }

        expected_pairs = replacements.map { |replacement| [operator.to_s, replacement.to_s] }
        actual_pairs = arithmetic.map { |m| [m[:original], m[:mutated]] }

        expect(actual_pairs).to match_array(expected_pairs)
      end
    end

    MutationTester::Mutator::MUTATIONS[:comparison].each do |operator, replacements|
      it "generates exactly #{replacements.inspect} for comparison operator #{operator.inspect}" do
        source = "a #{operator} b\n"
        comparison = mutations_for(source).select { |m| m[:type] == :comparison }

        expected_pairs = replacements.map { |replacement| [operator.to_s, replacement.to_s] }
        actual_pairs = comparison.map { |m| [m[:original], m[:mutated]] }

        expect(actual_pairs).to match_array(expected_pairs)
      end
    end
  end

  describe 'mutation_types switches' do
    ALL_TYPES = %i[arithmetic comparison logical boolean number string conditional call_removal nil_injection argument strict_equality].freeze
    DEFAULT_ENABLED_TYPES = (ALL_TYPES - [:strict_equality]).freeze

    MIXED_SOURCE = <<~RUBY
      def calc(a, b)
        x = a + b
        y = a > b
        eq = a == b
        z = a && b
        flag = true
        n = 2
        s = "hi"
        t = s.strip
        u = wrap(a)
        if a > b
          :yes
        end
      end
    RUBY

    def config_with_strict_equality
      config = MutationTester::Configuration.new
      config.mutation_types[:strict_equality] = true
      config
    end

    it 'generates the ten default mutation types and no strict equality probes on a default config' do
      types = mutations_for(MIXED_SOURCE).map { |m| m[:type] }.uniq

      expect(types).to match_array(DEFAULT_ENABLED_TYPES)
    end

    it 'generates all eleven mutation types when strict equality is opted in' do
      types = mutations_for(MIXED_SOURCE, config_with_strict_equality).map { |m| m[:type] }.uniq

      expect(types).to match_array(ALL_TYPES)
    end

    ALL_TYPES.each do |disabled_type|
      it "stops generating :#{disabled_type} mutants but keeps the others when :#{disabled_type} is disabled" do
        config = config_with_strict_equality
        config.mutation_types[disabled_type] = false

        types = mutations_for(MIXED_SOURCE, config).map { |m| m[:type] }.uniq

        expect(types).not_to include(disabled_type)
        expect(types).to match_array(ALL_TYPES - [disabled_type])
      end
    end
  end

  describe 'strict equality probes' do
    def strict_config
      config = MutationTester::Configuration.new
      config.mutation_types[:strict_equality] = true
      config
    end

    it 'replaces == with eql? and equal? when the mode is enabled' do
      strict = mutations_for("a == b\n", strict_config).select { |m| m[:type] == :strict_equality }

      expect(strict.map { |m| [m[:original], m[:mutated]] }).to match_array([%w[== eql?], %w[== equal?]])
      expect(strict.map { |m| m[:code] }).to match_array(["a.eql?(b)\n", "a.equal?(b)\n"])
      expect(strict.map { |m| m[:description] }).to match_array(['Change == to eql?', 'Change == to equal?'])
    end

    it 'keeps the comparison family mutations of == alongside the probes' do
      mutations = mutations_for("a == b\n", strict_config)
      comparison = mutations.select { |m| m[:type] == :comparison }

      expect(comparison.map { |m| m[:mutated] }).to match_array(%w[!= > <])
    end

    it 'generates no strict equality probes for != even when the mode is enabled' do
      strict = mutations_for("a != b\n", strict_config).select { |m| m[:type] == :strict_equality }

      expect(strict).to be_empty
    end

    it 'generates no strict equality probes on a default config' do
      strict = mutations_for("a == b\n").select { |m| m[:type] == :strict_equality }

      expect(strict).to be_empty
    end
  end

  describe 'number and boolean generators' do
    it 'mutates a float literal to 0, 1, and its increment/decrement' do
      number = mutations_for("x = 2.5\n").select { |m| m[:type] == :number }

      expect(number.map { |m| m[:mutated] }).to match_array(%w[0 1 3.5 1.5])
      expect(number.map { |m| m[:original] }.uniq).to eq(['2.5'])
      expect(number.map { |m| m[:code] }).to match_array(["x = 0\n", "x = 1\n", "x = 3.5\n", "x = 1.5\n"])
    end

    it 'mutates a negative integer literal to 0, 1, and its increment/decrement' do
      number = mutations_for("x = -5\n").select { |m| m[:type] == :number }

      expect(number.map { |m| m[:mutated] }).to match_array(%w[0 1 -4 -6])
      expect(number.map { |m| m[:original] }.uniq).to eq(['-5'])
      expect(number.map { |m| m[:code] }).to match_array(["x = 0\n", "x = 1\n", "x = -4\n", "x = -6\n"])
    end

    it 'does not generate a no-op "Change 1 to 1" mutant for literal 1' do
      number = mutations_for("x = 1\n").select { |m| m[:type] == :number }

      expect(number.map { |m| m[:description] }).not_to include('Change 1 to 1')
      expect(number.any? { |m| m[:original] == '1' && m[:mutated] == '1' }).to be(false)
      expect(number.map { |m| m[:description] }).to match_array(['Change 1 to 0', 'Increment 1 to 2'])
    end

    it 'generates the boolean happy path true->false and false->true' do
      boolean = mutations_for("a = true\nb = false\n").select { |m| m[:type] == :boolean }
      true_to_false = boolean.find { |m| m[:original] == 'true' }
      false_to_true = boolean.find { |m| m[:original] == 'false' }

      expect(true_to_false[:mutated]).to eq('false')
      expect(true_to_false[:description]).to eq('Change true to false')
      expect(true_to_false[:code]).to eq("a = false\nb = false\n")

      expect(false_to_true[:mutated]).to eq('true')
      expect(false_to_true[:description]).to eq('Change false to true')
      expect(false_to_true[:code]).to eq("a = true\nb = true\n")
    end
  end

  describe 'conditional negation for unless / ternary / elsif' do
    it 'negates the condition of an unless into a parseable !(...)' do
      conditional = mutations_for("unless a > b\n  do_it\nend\n")
                    .select { |m| m[:type] == :conditional }

      expect(conditional.size).to eq(1)
      mutant = conditional.first
      expect(mutant[:description]).to eq('Negate conditional expression')
      expect(mutant[:mutated]).to eq('!(a > b)')
      expect(mutant[:code]).to include('!(a > b)')
      expect { Parser::CurrentRuby.parse(mutant[:code]) }.not_to raise_error
    end

    it 'negates the condition of a ternary into a parseable !(...)' do
      conditional = mutations_for("a > b ? a : b\n")
                    .select { |m| m[:type] == :conditional }

      expect(conditional.size).to eq(1)
      mutant = conditional.first
      expect(mutant[:description]).to eq('Negate conditional expression')
      expect(mutant[:mutated]).to eq('!(a > b)')
      expect(mutant[:code]).to include('!(a > b) ? a : b')
      expect { Parser::CurrentRuby.parse(mutant[:code]) }.not_to raise_error
    end

    it 'negates the condition of an elsif branch into a parseable !(...)' do
      conditional = mutations_for("if a > b\n  :x\nelsif c > d\n  :y\nend\n")
                    .select { |m| m[:type] == :conditional }
      elsif_mutant = conditional.find { |m| m[:original] == 'c > d' }

      expect(elsif_mutant).not_to be_nil
      expect(elsif_mutant[:description]).to eq('Negate conditional expression')
      expect(elsif_mutant[:mutated]).to eq('!(c > d)')
      expect(elsif_mutant[:code]).to include('elsif !(c > d)')
      expect { Parser::CurrentRuby.parse(elsif_mutant[:code]) }.not_to raise_error
    end
  end

  describe 'extended operator mutations' do
    it 'mutates the power operator ** to * and + (arithmetic)' do
      arithmetic = mutations_for("a ** b\n").select { |m| m[:type] == :arithmetic }

      expect(arithmetic.map { |m| [m[:original], m[:mutated]] })
        .to match_array([%w[** *], %w[** +]])
      expect(arithmetic.map { |m| m[:code] }).to match_array(["a * b\n", "a + b\n"])
    end

    it 'mutates the **= compound assignment through the op_asgn path' do
      ops = mutations_for("a **= b\n").select { |m| m[:original] == '**=' }

      expect(ops.map { |m| m[:mutated] }).to match_array(%w[*= +=])
      expect(ops.map { |m| m[:code] }).to match_array(["a *= b\n", "a += b\n"])
      ops.each { |m| expect { Parser::CurrentRuby.parse(m[:code]) }.not_to raise_error }
    end

    it 'mutates ||= to &&= preserving the token style' do
      logical = mutations_for("a ||= b\n").select { |m| m[:type] == :logical }

      expect(logical.size).to eq(1)
      mutant = logical.first
      expect([mutant[:original], mutant[:mutated]]).to eq(%w[||= &&=])
      expect(mutant[:code]).to eq("a &&= b\n")
      expect(mutant[:description]).to eq('Change ||= to &&=')
      expect { Parser::CurrentRuby.parse(mutant[:code]) }.not_to raise_error
    end

    it 'mutates &&= to ||= preserving the token style' do
      logical = mutations_for("a &&= b\n").select { |m| m[:type] == :logical }

      expect(logical.size).to eq(1)
      mutant = logical.first
      expect([mutant[:original], mutant[:mutated]]).to eq(%w[&&= ||=])
      expect(mutant[:code]).to eq("a ||= b\n")
      expect(mutant[:description]).to eq('Change &&= to ||=')
      expect { Parser::CurrentRuby.parse(mutant[:code]) }.not_to raise_error
    end

    MutationTester::Mutator::MUTATIONS[:bitwise].each do |operator, replacements|
      it "generates exactly #{replacements.inspect} for bitwise op-assign #{operator}=" do
        ops = mutations_for("a #{operator}= b\n").select { |m| m[:original] == "#{operator}=" }

        expected_pairs = replacements.map { |replacement| ["#{operator}=", "#{replacement}="] }
        expect(ops.map { |m| [m[:original], m[:mutated]] }).to match_array(expected_pairs)
        ops.each { |m| expect { Parser::CurrentRuby.parse(m[:code]) }.not_to raise_error }
      end
    end

    it 'does not mutate plain bitwise send operators' do
      %w[| & ^].each do |op|
        originals = mutations_for("a #{op} b\n").map { |m| m[:original] }
        expect(originals).not_to include(op, "#{op}=")
      end
    end
  end

  describe 'logical operand removal' do
    def logical_for(source)
      mutations_for(source).select { |m| m[:type] == :logical }
    end

    def removals_for(source)
      logical_for(source).select { |m| m[:description].start_with?('Remove operand') }
    end

    it 'replaces a || b with each operand alongside the operator swap' do
      logical = logical_for("a || b\n")

      expect(logical.map { |m| m[:code] }).to match_array(["a && b\n", "a\n", "b\n"])
      expect(removals_for("a || b\n").map { |m| m[:description] })
        .to match_array(['Remove operand b from ||', 'Remove operand a from ||'])
    end

    it 'replaces a && b with each operand alongside the operator swap' do
      logical = logical_for("a && b\n")

      expect(logical.map { |m| m[:code] }).to match_array(["a || b\n", "a\n", "b\n"])
      expect(removals_for("a && b\n").map { |m| m[:description] })
        .to match_array(['Remove operand b from &&', 'Remove operand a from &&'])
    end

    it 'names the keyword operator in the description for and/or forms' do
      expect(removals_for("a and b\n").map { |m| [m[:code], m[:description]] })
        .to match_array([["a\n", 'Remove operand b from and'], ["b\n", 'Remove operand a from and']])
      expect(removals_for("a or b\n").map { |m| [m[:code], m[:description]] })
        .to match_array([["a\n", 'Remove operand b from or'], ["b\n", 'Remove operand a from or']])
    end

    it 'reports the kept operand as mutated and the full expression as original' do
      removal = removals_for("@vip || amount >= limit\n")
                .find { |m| m[:description] == 'Remove operand @vip from ||' }

      expect(removal[:original]).to eq('@vip || amount >= limit')
      expect(removal[:mutated]).to eq('amount >= limit')
      expect(removal[:code]).to eq("amount >= limit\n")
    end

    it 'removes each operand of a chain per logical node without duplicates' do
      removals = removals_for("a || b || c\n")

      codes = removals.map { |m| m[:code] }
      expect(codes).to match_array(["a || b\n", "c\n", "a || c\n", "b || c\n"])
      expect(codes.uniq.size).to eq(codes.size)
    end

    it 'handles an operand on the following line by collapsing the expression' do
      removals = removals_for("x = a ||\n    b\n")

      expect(removals.map { |m| m[:code] }).to match_array(["x = a\n", "x = b\n"])
      removals.each do |m|
        expect { Parser::CurrentRuby.parse(m[:code]) }.not_to raise_error
      end
    end

    it 'drops a removal candidate whose code no longer parses' do
      allow(Unparser).to receive(:unparse).and_return('(')

      logical = logical_for("a || b\n")

      expect(logical.map { |m| m[:description] }).to eq(['Change || to &&'])
    end

    it 'emits no removal mutants when the logical type is disabled' do
      config = MutationTester::Configuration.new
      config.mutation_types[:logical] = false

      expect(mutations_for("a || b\n", config).select { |m| m[:type] == :logical }).to be_empty
    end
  end

  describe 'while/until loop condition negation' do
    {
      'while statement'  => ["while a > b\n  x\nend\n", 'while !(a > b)'],
      'until statement'  => ["until a > b\n  x\nend\n", 'until !(a > b)'],
      'while modifier'   => ["x while a > b\n", 'x while !(a > b)'],
      'until modifier'   => ["x until a > b\n", 'x until !(a > b)'],
      'while post-loop'  => ["begin\n  x\nend while a > b\n", 'while !(a > b)'],
      'until post-loop'  => ["begin\n  x\nend until a > b\n", 'until !(a > b)']
    }.each do |form, (source, expected_fragment)|
      it "negates the condition of a #{form} into a parseable !(...)" do
        conditional = mutations_for(source).select { |m| m[:type] == :conditional }

        expect(conditional.size).to eq(1)
        mutant = conditional.first
        expect(mutant[:description]).to eq('Negate conditional expression')
        expect(mutant[:original]).to eq('a > b')
        expect(mutant[:mutated]).to eq('!(a > b)')
        expect(mutant[:code]).to include(expected_fragment)
        expect(mutant[:code]).not_to eq(source)
        expect { Parser::CurrentRuby.parse(mutant[:code]) }.not_to raise_error
      end
    end

    it 'gates while/until negation behind the :conditional switch' do
      source = "while a > b\n  x\nend\nuntil c < d\n  y\nend\n"

      enabled = mutations_for(source).select { |m| m[:type] == :conditional }
      expect(enabled.map { |m| m[:mutated] }).to match_array(['!(a > b)', '!(c < d)'])

      config = MutationTester::Configuration.new
      config.mutation_types[:conditional] = false
      disabled = mutations_for(source, config).select { |m| m[:type] == :conditional }
      expect(disabled).to be_empty
    end
  end

  describe 'mutation_tester:disable line exclusion' do
    def mutator_after(source, config = MutationTester::Configuration.new)
      mutator = build_mutator(source, config)
      mutator.generate_mutations(Parser::CurrentRuby.parse(source))
      mutator
    end

    it 'generates no mutants for an annotated line but mutates the rest of the file' do
      mutations = mutations_for("x = a + b # mutation_tester:disable\ny = a - b\n")

      expect(mutations.select { |m| m[:line] == 1 }).to be_empty
      expect(mutations.select { |m| m[:line] == 2 }).not_to be_empty
    end

    it 'mutates the line normally once the annotation is removed' do
      mutations = mutations_for("x = a + b\ny = a - b\n")

      expect(mutations.select { |m| m[:line] == 1 }).not_to be_empty
    end

    {
      arithmetic: "z = a + b # mutation_tester:disable\n",
      comparison: "z = a > b # mutation_tester:disable\n",
      logical: "z = a && b # mutation_tester:disable\n",
      boolean: "z = true # mutation_tester:disable\n",
      number: "z = 5 # mutation_tester:disable\n",
      string: "z = \"hi\" # mutation_tester:disable\n",
      conditional: "if a > b # mutation_tester:disable\n  x\nend\n"
    }.each do |type, source|
      it "excludes #{type} mutants generated on the annotated line" do
        on_line1 = mutations_for(source).select { |m| m[:line] == 1 }

        expect(on_line1).to be_empty
      end
    end

    it 'excludes a multiline node anchored on the annotated line' do
      source = <<~RUBY
        if a > b && # mutation_tester:disable
           c < d
          do_it
        end
      RUBY

      expect(mutations_for(source).select { |m| m[:line] == 1 }).to be_empty
      expect(mutations_for(source).select { |m| m[:line] == 2 }).not_to be_empty
    end

    it 'counts the excluded mutants in excluded_count without touching skipped_count' do
      mutator = mutator_after("z = a > b # mutation_tester:disable\n")

      expect(mutator.excluded_count).to eq(4)
      expect(mutator.skipped_count).to eq(0)
    end

    it 'leaves a file without any annotation unchanged' do
      mutator = build_mutator("x = a + b\ny = a > b\n")
      mutations = mutator.generate_mutations(Parser::CurrentRuby.parse("x = a + b\ny = a > b\n"))

      expect(mutator.excluded_count).to eq(0)
      expect(mutations.map { |m| m[:line] }.uniq).to match_array([1, 2])
    end

    it 'is a no-op when the annotation sits on a line with no mutable nodes' do
      source = "# mutation_tester:disable\nx = a + b\n"
      mutator = build_mutator(source)
      mutations = mutator.generate_mutations(Parser::CurrentRuby.parse(source))

      expect(mutator.excluded_count).to eq(0)
      expect(mutations.map { |m| m[:line] }.uniq).to eq([2])
    end

    it 'does not treat the marker text inside a string literal as an annotation' do
      mutations = mutations_for("z = \"mutation_tester:disable\"\n")

      expect(mutations.select { |m| m[:type] == :string && m[:line] == 1 }).not_to be_empty
    end
  end

  describe 'case/when branch deletion' do
    def when_deletions(source, config = MutationTester::Configuration.new)
      mutations_for(source, config).select { |m| m[:description] == 'Remove when branch' }
    end

    CASE_WITH_ELSE = <<~RUBY
      case x
      when 1 then :a
      when 2 then :b
      else :c
      end
    RUBY

    it 'generates one :conditional deletion mutant per when clause, all re-parsing' do
      deletions = when_deletions(CASE_WITH_ELSE)

      expect(deletions.size).to eq(2)
      expect(deletions.map { |m| m[:type] }.uniq).to eq([:conditional])
      expect(deletions.map { |m| m[:line] }).to match_array([2, 3])
      expect(deletions.map { |m| m[:source_line] })
        .to match_array(['when 1 then :a', 'when 2 then :b'])
      deletions.each do |mutant|
        expect(mutant[:code]).not_to eq(CASE_WITH_ELSE)
        expect { Parser::CurrentRuby.parse(mutant[:code]) }.not_to raise_error
      end
    end

    it 'removes the targeted when clause and keeps the rest of the case' do
      first = when_deletions(CASE_WITH_ELSE).find { |m| m[:line] == 2 }

      expect(first[:code]).not_to include('when 1')
      expect(first[:code]).to include('when 2')
      expect(first[:code]).to include('else')
    end

    it 'does not generate a deletion mutant for a single-when case (would not parse)' do
      single = <<~RUBY
        case x
        when 1 then :a
        end
      RUBY

      expect(when_deletions(single)).to be_empty
    end

    it 'deletes when clauses of a subjectless case' do
      subjectless = <<~RUBY
        case
        when a > 1 then :a
        when a > 2 then :b
        end
      RUBY

      expect(when_deletions(subjectless).size).to eq(2)
    end

    it 'gates case/when deletion behind the :conditional switch' do
      expect(when_deletions(CASE_WITH_ELSE)).not_to be_empty

      config = MutationTester::Configuration.new
      config.mutation_types[:conditional] = false
      expect(when_deletions(CASE_WITH_ELSE, config)).to be_empty
    end

    it 'does not mutate case/in pattern matching' do
      pattern = <<~RUBY
        case x
        in 1 then :a
        in 2 then :b
        end
      RUBY

      expect(when_deletions(pattern)).to be_empty
    end
  end

  describe 'pure call removal' do
    def call_removals(source, config = MutationTester::Configuration.new)
      mutations_for(source, config).select { |m| m[:type] == :call_removal }
    end

    it 'replaces a whitelisted no-argument call with its receiver' do
      removals = call_removals("items.uniq\n")

      expect(removals.size).to eq(1)
      expect(removals.first[:original]).to eq('items.uniq')
      expect(removals.first[:mutated]).to eq('items')
      expect(removals.first[:code]).to eq("items\n")
      expect(removals.first[:description]).to eq('Remove uniq call')
    end

    MutationTester::Mutator::PURE_TRANSFORMATIONS.each do |method_name|
      it "generates a removal mutant for a bare #{method_name} call on a receiver" do
        removals = call_removals("value.#{method_name}\n")

        expect(removals.map { |m| [m[:original], m[:mutated]] })
          .to eq([["value.#{method_name}", 'value']])
      end
    end

    it 'removes a call in the middle of a chain' do
      removals = call_removals("items.uniq.sum\n")

      expect(removals.map { |m| m[:code] }).to eq(["items.sum\n"])
    end

    it 'removes a whitelisted call inside a multi-line chain' do
      source = <<~RUBY
        items
          .uniq
          .sum
      RUBY

      removals = call_removals(source)

      expect(removals.size).to eq(1)
      expect(removals.first[:code]).to eq("items\n  .sum\n")
      expect { Parser::CurrentRuby.parse(removals.first[:code]) }.not_to raise_error
    end

    it 'does not remove calls with arguments' do
      expect(call_removals("value.round(2)\n")).to be_empty
    end

    it 'does not remove calls with a block' do
      expect(call_removals("items.sort { |a, b| b.foo(a) }\n")).to be_empty
    end

    it 'does not remove non-whitelisted methods' do
      expect(call_removals("items.sum\n")).to be_empty
    end

    it 'does not remove behavior-preserving freeze and dup calls' do
      expect(call_removals("CONST.freeze\n")).to be_empty
      expect(call_removals("value.dup\n")).to be_empty
    end

    it 'does not remove receiverless calls' do
      expect(call_removals("uniq\n")).to be_empty
    end

    it 'does not remove safe-navigation calls' do
      expect(call_removals("items&.uniq\n")).to be_empty
    end

    it 'gates call removal behind the :call_removal switch' do
      config = MutationTester::Configuration.new
      config.mutation_types[:call_removal] = false

      expect(call_removals("items.uniq\n", config)).to be_empty
    end

    it 'drops a removal candidate whose code does not re-parse instead of emitting it' do
      source = "items.uniq\n"
      mutator = build_mutator(source)
      allow(mutator).to receive(:parses_cleanly?).and_return(false)

      mutations = mutator.generate_mutations(Parser::CurrentRuby.parse(source))

      expect(mutations.select { |m| m[:type] == :call_removal }).to be_empty
    end
  end

  describe 'argument mutations' do
    def argument_mutations(source, config = MutationTester::Configuration.new)
      mutations_for(source, config).select { |m| m[:type] == :argument }
    end

    def removals(source)
      argument_mutations(source).select { |m| m[:description].start_with?('Remove last argument') }
    end

    def nil_substitutions(source)
      argument_mutations(source).select { |m| m[:description].end_with?('with nil') }
    end

    it 'removes the last argument of a multi-argument call keeping the parentheses' do
      expect(removals("m(a, b)\n").map { |m| m[:code] }).to eq(["m(a)\n"])
    end

    it 'removes the only argument of a parenthesized call down to empty parentheses' do
      expect(removals("m(a)\n").map { |m| m[:code] }).to eq(["m()\n"])
    end

    it 'removes the only argument of a paren-free call keeping the paren-free style' do
      expect(removals("raise 'msg'\n").map { |m| m[:code] }).to eq(["raise\n"])
    end

    it 'removes the last argument of a paren-free multi-argument call' do
      expect(removals("m a, b\n").map { |m| m[:code] }).to eq(["m a\n"])
    end

    it 'removes only the last argument of a two-argument raise, never both' do
      removal_codes = removals("raise ArgumentError, msg\n").map { |m| m[:code] }

      expect(removal_codes).to eq(["raise ArgumentError\n"])
      expect(removal_codes).not_to include("raise\n")
    end

    it 'substitutes nil for each argument separately' do
      expect(nil_substitutions("m(a, b)\n").map { |m| m[:code] })
        .to match_array(["m(nil, b)\n", "m(a, nil)\n"])
    end

    it 'does not substitute nil for an argument that is already the nil literal' do
      expect(nil_substitutions("m(a, nil)\n").map { |m| m[:code] }).to eq(["m(nil, nil)\n"])
    end

    it 'reports the whole call as original and the mutated call with a naming description' do
      removal = removals("calc.sum(a, b)\n").first

      expect(removal[:original]).to eq('calc.sum(a, b)')
      expect(removal[:mutated]).to eq('calc.sum(a)')
      expect(removal[:description]).to eq('Remove last argument from sum')

      substitution = nil_substitutions("calc.sum(a, b)\n")
                     .find { |m| m[:code] == "calc.sum(a, nil)\n" }
      expect(substitution[:mutated]).to eq('calc.sum(a, nil)')
      expect(substitution[:description]).to eq('Replace argument b with nil')
    end

    it 'does not mutate arguments of operator sends' do
      ["a + b\n", "a == b\n", "a[1]\n", "a[1] = 2\n", "list << item\n"].each do |source|
        expect(argument_mutations(source)).to be_empty
      end
    end

    it 'does not mutate arguments of require-like calls' do
      ["require 'json'\n", "require_relative 'helper'\n", "load 'config.rb'\n", "autoload :Foo, 'foo'\n"].each do |source|
        expect(argument_mutations(source)).to be_empty
      end
    end

    it 'does not mutate a block-pass argument and does not remove it as last argument' do
      expect(argument_mutations("m(&blk)\n")).to be_empty
      expect(argument_mutations("m(a, &blk)\n").map { |m| m[:code] }).to eq(["m(nil, &blk)\n"])
    end

    it 'does not mutate a splat argument and does not remove it as last argument' do
      expect(argument_mutations("m(*args)\n")).to be_empty
      expect(argument_mutations("m(a, *rest)\n").map { |m| m[:code] }).to eq(["m(nil, *rest)\n"])
    end

    it 'does not mutate a double-splat argument and does not remove it as last argument' do
      expect(argument_mutations("m(**opts)\n")).to be_empty
      expect(argument_mutations("m(a, **opts)\n").map { |m| m[:code] }).to eq(["m(nil, **opts)\n"])
    end

    it 'drops an argument candidate whose code does not re-parse instead of emitting it' do
      source = "m(a, b)\n"
      mutator = build_mutator(source)
      allow(mutator).to receive(:parses_cleanly?).and_return(false)

      mutations = mutator.generate_mutations(Parser::CurrentRuby.parse(source))

      expect(mutations.select { |m| m[:type] == :argument }).to be_empty
    end

    it 'gates argument mutations behind the :argument switch' do
      config = MutationTester::Configuration.new
      config.mutation_types[:argument] = false

      expect(argument_mutations("m(a, b)\n")).not_to be_empty
      expect(mutations_for("m(a, b)\n", config).select { |m| m[:type] == :argument }).to be_empty
    end
  end

  describe 'hash pair removal in call arguments' do
    def pair_removals(source, config = MutationTester::Configuration.new)
      mutations_for(source, config).select { |m| m[:description].start_with?('Remove pair') }
    end

    it 'removes each keyword option separately so a test of one option is the only one that can kill its mutant' do
      source = "validates :role, presence: true, inclusion: ROLES\n"

      expect(pair_removals(source).map { |m| m[:code] })
        .to eq(["validates :role, inclusion: ROLES\n", "validates :role, presence: true\n"])
    end

    it 'removes a middle pair without touching its neighbors' do
      expect(pair_removals("m(a: 1, b: 2, c: 3)\n").map { |m| m[:code] })
        .to eq(["m(b: 2, c: 3)\n", "m(a: 1, c: 3)\n", "m(a: 1, b: 2)\n"])
    end

    it 'removes pairs of an option hash nested as a pair value' do
      source = "validates :email, uniqueness: { scope: :account_id, case_sensitive: false }\n"

      expect(pair_removals(source).map { |m| m[:code] }).to eq(
        [
          "validates :email, uniqueness: { case_sensitive: false }\n",
          "validates :email, uniqueness: { scope: :account_id }\n"
        ]
      )
    end

    it 'empties a braced single-pair hash, including one written with a trailing comma' do
      expect(pair_removals("m(flash: { notice: text })\n").map { |m| m[:code] }).to eq(["m(flash: {})\n"])
      expect(pair_removals("m({ a: 1, })\n").map { |m| m[:code] }).to eq(["m({})\n"])
    end

    it 'leaves a lone brace-free keyword that ends the call alone because removing it is the last-argument removal' do
      expect(pair_removals("m(a, k: 1)\n")).to be_empty
      expect(pair_removals("m k: 1\n")).to be_empty
    end

    it 'removes a lone brace-free keyword followed by a block pass, which the last-argument removal cannot reach' do
      expect(pair_removals("m(a, k: 1, &blk)\n").map { |m| m[:code] }).to eq(["m(a, &blk)\n"])
      expect(pair_removals("m(k: 1, &blk)\n").map { |m| m[:code] }).to eq(["m(&blk)\n"])
    end

    it 'removes a pair of a call spread over several lines' do
      source = "before_action :load,\n              only: ACTIONS,\n              if: :admin?\n"

      expect(pair_removals(source).map { |m| m[:code] }).to eq(
        [
          "before_action :load,\n              if: :admin?\n",
          "before_action :load,\n              only: ACTIONS\n"
        ]
      )
    end

    it 'reports a pair of a multi-line call on the line of that pair so it can be read and annotated there' do
      source = "m(\n  a: 1,\n  b: 2\n)\n"

      expect(pair_removals(source).map { |m| m.slice(:line, :source_line, :mutated_line) }).to eq(
        [
          { line: 2, source_line: 'a: 1,', mutated_line: '(pair removed)' },
          { line: 3, source_line: 'b: 2', mutated_line: '(pair removed)' }
        ]
      )
    end

    it 'shows the mutated line itself when the removed pair does not span a line break' do
      removal = pair_removals("m(a: 1, b: 2,\n  c: 3)\n").first

      expect(removal.slice(:line, :source_line, :mutated_line))
        .to eq(line: 1, source_line: 'm(a: 1, b: 2,', mutated_line: 'm(b: 2,')
    end

    it 'excludes only the annotated pair of a multi-line call' do
      source = "m(\n  a: 1, # mutation_tester:disable\n  b: 2\n)\n"

      expect(pair_removals(source).map { |m| m[:description] }).to eq(['Remove pair b from m'])
    end

    it 'handles hash-rocket and string keys' do
      expect(pair_removals("m(:a => 1, 'b' => 2)\n").map { |m| m[:code] })
        .to eq(["m('b' => 2)\n", "m(:a => 1)\n"])
    end

    it 'does not touch a hash that carries a double splat, whose keys may repeat the removed pair' do
      expect(pair_removals("m(a: 1, b: 2, **opts)\n")).to be_empty
    end

    it 'keeps the other argument mutants of a call that forwards an anonymous double splat' do
      skip 'Anonymous double splat forwarding is unparseable before Ruby 3.2' if Gem::Version.new(RUBY_VERSION) < Gem::Version.new('3.2')

      source = "def f(**)\n  g(x, a: 1, b: 2, **)\nend\n"
      mutator = build_mutator(source)
      descriptions = mutator.generate_mutations(Parser::CurrentRuby.parse(source))
                            .select { |m| m[:type] == :argument }.map { |m| m[:description] }

      expect(descriptions).to eq(
        ['Remove last argument from g', 'Replace argument x with nil', 'Replace argument a: 1, b: 2, ** with nil']
      )
      expect(mutator.skipped_count).to eq(0)
    end

    it 'keeps the last-argument and nil mutants of a call whose pair removal raises' do
      source = "m(a: 1, b: 2)\n"
      mutator = build_mutator(source)
      allow(mutator).to receive(:pair_removal_range).and_raise(StandardError, 'boom')

      mutations = nil
      expect { mutations = mutator.generate_mutations(Parser::CurrentRuby.parse(source)) }
        .to output(/skipped 1/).to_stdout
      descriptions = mutations.select { |m| m[:type] == :argument }.map { |m| m[:description] }

      expect(descriptions).to eq(['Remove last argument from m', 'Replace argument a: 1, b: 2 with nil'])
      expect(mutator.skipped_count).to eq(1)
    end

    it 'does not remove a pair that opens a heredoc, whose body would be left orphaned, but removes its sibling' do
      expect(pair_removals("m(a: <<~TEXT, b: 2)\n  body\nTEXT\n").map { |m| m[:code] })
        .to eq(["m(a: <<~TEXT)\n  body\nTEXT\n"])
    end

    it 'does not remove a pair when the removed text would swallow the body of a heredoc passed beside it' do
      source = "m(<<~TEXT, a: 1,\n  body\nTEXT\n  b: 2)\nn(<<~TEXT)\n  other\nTEXT\n"

      expect(pair_removals(source)).to be_empty
    end

    it 'does not touch hash literals outside call arguments or arguments of operator sends' do
      ["PRICES = { pencil: 1, book: 2 }\n", "store[:k] = { a: 1, b: 2 }\n", "list << { a: 1, b: 2 }\n"].each do |source|
        expect(pair_removals(source)).to be_empty
      end
    end

    it 'reports the whole call as original and the call without the pair as mutated under the argument type' do
      removal = pair_removals("user.update(name: name, role: role)\n").first

      expect(removal[:type]).to eq(:argument)
      expect(removal[:original]).to eq('user.update(name: name, role: role)')
      expect(removal[:mutated]).to eq('user.update(role: role)')
      expect(removal[:description]).to eq('Remove pair name from update')
    end

    it 'drops a pair removal whose code does not re-parse instead of emitting it' do
      source = "m(a: 1, b: 2)\n"
      mutator = build_mutator(source)
      allow(mutator).to receive(:parses_cleanly?).and_return(false)

      mutations = mutator.generate_mutations(Parser::CurrentRuby.parse(source))

      expect(mutations.select { |m| m[:description].start_with?('Remove pair') }).to be_empty
    end

    it 'gates pair removal behind the :argument switch' do
      config = MutationTester::Configuration.new
      config.mutation_types[:argument] = false

      expect(pair_removals("m(a: 1, b: 2)\n")).not_to be_empty
      expect(pair_removals("m(a: 1, b: 2)\n", config)).to be_empty
    end
  end

  describe 'range boundary mutations' do
    def range_swaps(source, config = MutationTester::Configuration.new)
      mutations_for(source, config).select { |m| m[:description].start_with?('Change ..') }
    end

    it 'turns an inclusive range into an exclusive one so a test at the upper bound is needed to kill it' do
      expect(range_swaps("(1..limit).to_a\n").map { |m| m[:code] }).to eq(["(1...limit).to_a\n"])
    end

    it 'turns an exclusive range into an inclusive one' do
      expect(range_swaps("text[0...limit]\n").map { |m| m[:code] }).to eq(["text[0..limit]\n"])
    end

    it 'mutates a beginless range, whose upper bound still decides membership' do
      expect(range_swaps("x = (..5)\n").map { |m| m[:code] }).to eq(["x = (...5)\n"])
    end

    it 'mutates a range used as a when condition' do
      source = "case n\nwhen 1..5 then :low\nelse :high\nend\n"

      expect(range_swaps(source).map { |m| m[:mutated_line] }).to eq(['when 1...5 then :low'])
    end

    it 'leaves an endless range alone because both forms contain the same values' do
      expect(range_swaps("x = (1..)\n")).to be_empty
      expect(range_swaps("text[1..]\n")).to be_empty
      expect(range_swaps("x = (1..nil)\n")).to be_empty
      expect(range_swaps("y = x[1..nil]\nz = x[1...nil]\n")).to be_empty
    end

    it 'leaves a range ending at infinity alone because the bound can never be reached' do
      expect(range_swaps("x = (1..Float::INFINITY)\n")).to be_empty
    end

    it 'leaves a flip-flop alone' do
      expect(range_swaps("puts line if (line == 1)..(line == 3)\n")).to be_empty
    end

    it 'reports the operator swap under the comparison type on the line of the operator' do
      swap = range_swaps("x = 1\ny = (a..b)\n").first

      expect(swap[:type]).to eq(:comparison)
      expect(swap[:line]).to eq(2)
      expect(swap[:original]).to eq('..')
      expect(swap[:mutated]).to eq('...')
      expect(swap[:description]).to eq('Change .. to ...')
    end

    it 'gates the range swap behind the :comparison switch' do
      config = MutationTester::Configuration.new
      config.mutation_types[:comparison] = false

      expect(range_swaps("(a..b)\n")).not_to be_empty
      expect(range_swaps("(a..b)\n", config)).to be_empty
    end
  end

  describe 'default value mutations' do
    def default_mutations(source, config = MutationTester::Configuration.new)
      mutations_for(source, config).select do |m|
        m[:type] == :argument && m[:description].include?('default value')
      end
    end

    it 'removes a non-literal positional default and replaces it with nil' do
      source = "def m(x, opts = {})\n  opts\nend\n"

      expect(default_mutations(source).map { |m| m[:code].lines.first })
        .to match_array(["def m(x, opts)\n", "def m(x, opts = nil)\n"])
    end

    it 'mutates a method-call default expression structurally' do
      source = "def m(config = Configuration.new)\n  config\nend\n"

      expect(default_mutations(source).map { |m| m[:code].lines.first })
        .to match_array(["def m(config)\n", "def m(config = nil)\n"])
    end

    it 'makes a keyword default required and replaces it with nil' do
      source = "def m(a, b: compute)\n  b\nend\n"

      expect(default_mutations(source).map { |m| m[:code].lines.first })
        .to match_array(["def m(a, b:)\n", "def m(a, b: nil)\n"])
    end

    it 'reports the original parameter and the mutated parameter under the argument type' do
      removal = default_mutations("def m(x, opts = {})\n  opts\nend\n")
                .find { |m| m[:description] == 'Remove default value of opts' }

      expect(removal[:type]).to eq(:argument)
      expect(removal[:original]).to eq('opts = {}')
      expect(removal[:mutated]).to eq('opts')
      expect(removal[:line]).to eq(1)
    end

    it 'only removes the default when it is already the nil literal' do
      source = "def m(a, b = nil)\n  b\nend\n"

      expect(default_mutations(source).map { |m| m[:code].lines.first })
        .to eq(["def m(a, b)\n"])
    end

    it 'only removes a keyword default that is the false literal, skipping the equivalent nil variant' do
      source = "def m(vip: false)\n  vip\nend\n"

      expect(default_mutations(source).map { |m| m[:code].lines.first })
        .to eq(["def m(vip:)\n"])
    end

    it 'only removes a positional default that is the false literal, skipping the equivalent nil variant' do
      source = "def m(a, b = false)\n  b\nend\n"

      expect(default_mutations(source).map { |m| m[:code].lines.first })
        .to eq(["def m(a, b)\n"])
    end

    it 'generates only the nil variant for an optional parameter placed before a required one' do
      source = "def m(a = 1, b)\n  b\nend\n"

      expect(default_mutations(source).map { |m| m[:code].lines.first })
        .to eq(["def m(a = nil, b)\n"])
    end

    it 'still makes a keyword default required when an optional positional precedes a required one' do
      source = "def m(a = 1, b, c: 2)\n  b\nend\n"

      expect(default_mutations(source).map { |m| m[:code].lines.first })
        .to match_array(["def m(a = nil, b, c: 2)\n", "def m(a = 1, b, c:)\n", "def m(a = 1, b, c: nil)\n"])
    end

    it 'mutates defaults of singleton method definitions' do
      source = "def self.m(b = [])\n  b\nend\n"

      expect(default_mutations(source).map { |m| m[:code].lines.first })
        .to match_array(["def self.m(b)\n", "def self.m(b = nil)\n"])
    end

    it 'does not mutate parameters without defaults, splats, or block parameters' do
      expect(default_mutations("def m(a, *rest, **opts, &blk)\n  a\nend\n")).to be_empty
    end

    it 'drops a default candidate whose code does not re-parse instead of emitting it' do
      source = "def m(x, opts = {})\n  opts\nend\n"
      mutator = build_mutator(source)
      allow(mutator).to receive(:parses_cleanly?).and_return(false)

      mutations = mutator.generate_mutations(Parser::CurrentRuby.parse(source))

      expect(mutations.select { |m| m[:type] == :argument }).to be_empty
    end

    it 'gates default value mutations behind the :argument switch' do
      source = "def m(x, opts = {})\n  opts\nend\n"
      config = MutationTester::Configuration.new
      config.mutation_types[:argument] = false

      expect(default_mutations(source)).not_to be_empty
      expect(default_mutations(source, config)).to be_empty
    end
  end

  describe 'enclosing method tagging' do
    it 'tags each mutation with the name of the enclosing instance method' do
      source = <<~RUBY
        class Calc
          def add(a, b)
            a + b
          end

          def sub(a, b)
            a - b
          end
        end
      RUBY

      by_method = mutations_for(source).group_by { |m| m[:method_name] }

      expect(by_method.keys).to contain_exactly('add', 'sub')
      expect(by_method['add'].map { |m| m[:line] }).to all(eq(3))
      expect(by_method['sub'].map { |m| m[:line] }).to all(eq(7))
    end

    it 'tags mutations inside a singleton method with its name' do
      source = <<~RUBY
        class Calc
          def self.double(a)
            a * 2
          end
        end
      RUBY

      expect(mutations_for(source).map { |m| m[:method_name] }).to all(eq('double'))
    end

    it 'tags a mutation inside a nested block with the enclosing method name' do
      source = <<~RUBY
        class Calc
          def total(items)
            items.sum { |item| item + 1 }
          end
        end
      RUBY

      expect(mutations_for(source).map { |m| m[:method_name] }).to all(eq('total'))
    end

    it 'leaves mutations outside any method untagged' do
      expect(mutations_for("x = 1 + 2\n").map { |m| m[:method_name] }).to all(be_nil)
    end
  end

  describe 'nil injection' do
    def nil_injections(source, config = MutationTester::Configuration.new)
      mutations_for(source, config).select { |m| m[:type] == :nil_injection }
    end

    it 'replaces the last expression of a multi-statement method body with nil' do
      source = <<~RUBY
        def total(items)
          validate(items)
          items.sum
        end
      RUBY

      injections = nil_injections(source)

      expect(injections.size).to eq(1)
      expect(injections.first[:original]).to eq('items.sum')
      expect(injections.first[:mutated]).to eq('nil')
      expect(injections.first[:code]).to eq("def total(items)\n  validate(items)\n  nil\nend\n")
      expect(injections.first[:description]).to eq('Replace method return value with nil')
    end

    it 'replaces the whole body of a single-expression method with nil' do
      source = <<~RUBY
        def name
          build_name
        end
      RUBY

      expect(nil_injections(source).map { |m| m[:code] }).to eq(["def name\n  nil\nend\n"])
    end

    it 'replaces a final self with nil' do
      source = <<~RUBY
        def register!(item)
          @items = item
          self
        end
      RUBY

      self_mutant = nil_injections(source).find { |m| m[:original] == 'self' }

      expect(self_mutant).not_to be_nil
      expect(self_mutant[:code]).to eq("def register!(item)\n  @items = item\n  nil\nend\n")
    end

    it 'replaces the last expression of a singleton method with nil' do
      source = <<~RUBY
        def self.build
          new
        end
      RUBY

      expect(nil_injections(source).map { |m| m[:code] }).to eq(["def self.build\n  nil\nend\n"])
    end

    it 'does not mutate a method whose last expression is already nil' do
      source = <<~RUBY
        def noop
          nil
        end
      RUBY

      expect(nil_injections(source)).to be_empty
    end

    it 'does not mutate a method with an empty body' do
      expect(nil_injections("def noop\nend\n")).to be_empty
    end

    it 'does not mutate a method whose body ends in a rescue clause' do
      source = <<~RUBY
        def risky
          danger
        rescue StandardError
          :fallback
        end
      RUBY

      expect(nil_injections(source)).to be_empty
    end

    it 'replaces the right-hand side of an instance variable assignment with nil' do
      injections = nil_injections("@count = compute\n")

      expect(injections.size).to eq(1)
      expect(injections.first[:original]).to eq('compute')
      expect(injections.first[:mutated]).to eq('nil')
      expect(injections.first[:code]).to eq("@count = nil\n")
      expect(injections.first[:description]).to eq('Assign nil to @count')
    end

    it 'does not mutate an instance variable already assigned nil' do
      expect(nil_injections("@count = nil\n")).to be_empty
    end

    it 'does not mutate the target of a memoized ||= assignment' do
      expect(nil_injections("@memo ||= 5\n")).to be_empty
    end

    it 'generates both the return-value and the assignment mutant for a trailing ivar assignment' do
      source = <<~RUBY
        def store(value)
          @value = value
        end
      RUBY

      expect(nil_injections(source).map { |m| m[:code] }).to match_array([
        "def store(value)\n  nil\nend\n",
        "def store(value)\n  @value = nil\nend\n"
      ])
    end

    it 'gates nil injection behind the :nil_injection switch' do
      config = MutationTester::Configuration.new
      config.mutation_types[:nil_injection] = false

      source = <<~RUBY
        def register!(item)
          @items = item
          self
        end
      RUBY

      expect(nil_injections(source, config)).to be_empty
    end

    it 'drops a nil-injection candidate whose code does not re-parse instead of emitting it' do
      source = "def name\n  build_name\nend\n"
      mutator = build_mutator(source)
      allow(mutator).to receive(:parses_cleanly?).and_return(false)

      mutations = mutator.generate_mutations(Parser::CurrentRuby.parse(source))

      expect(mutations.select { |m| m[:type] == :nil_injection }).to be_empty
    end
  end

  describe 'in-memory-safe classification by AST context' do
    def safe_by_line(source)
      mutations_for(source).group_by { |m| m[:line] }
        .transform_values { |ms| ms.map { |m| m[:in_memory_safe] }.uniq }
    end

    it 'tags every mutation with a boolean in_memory_safe flag' do
      mutations = mutations_for("class Foo\n  def bar(a)\n    a + 1\n  end\nend\n")

      expect(mutations).not_to be_empty
      expect(mutations.map { |m| m[:in_memory_safe] }).to all(be(true).or(be(false)))
    end

    it 'marks a method body defined directly in the class as in-memory-safe' do
      by_line = safe_by_line("class Foo\n  def bar(a)\n    a + 1\n  end\nend\n")

      expect(by_line[3]).to eq([true])
    end

    it 'marks a class-body constant as not in-memory-safe' do
      by_line = safe_by_line("class Foo\n  RATE = 5\n  def bar(a)\n    a + RATE\n  end\nend\n")

      expect(by_line[2]).to eq([false])
      expect(by_line[4]).to eq([true])
    end

    it 'marks a method and macro inside included do as not in-memory-safe' do
      source = <<~RUBY
        module Sample
          included do
            validates :name
            def helper(x)
              x + 1
            end
          end
        end
      RUBY
      by_line = safe_by_line(source)

      expect(by_line.values.flatten.uniq).to eq([false])
    end

    it 'marks a method inside a class nested in a class-body block as not in-memory-safe' do
      source = <<~RUBY
        module Sample
          included do
            class Inner
              def helper(x)
                x + 1
              end
            end
          end
        end
      RUBY
      by_line = safe_by_line(source)

      expect(by_line.values.flatten.uniq).to eq([false])
    end

    it 'keeps a plain nested class method in-memory-safe' do
      source = "class Outer\n  class Inner\n    def bar(a)\n      a + 1\n    end\n  end\nend\n"
      by_line = safe_by_line(source)

      expect(by_line[4]).to eq([true])
    end

    it 'keeps a block nested inside a method body in-memory-safe' do
      source = <<~RUBY
        class Foo
          def bar(items)
            items.each { |i| i + 1 }
          end
        end
      RUBY
      by_line = safe_by_line(source)

      expect(by_line[3]).to eq([true])
    end
  end
end
