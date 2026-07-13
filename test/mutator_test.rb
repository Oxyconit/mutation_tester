gem 'minitest', '~> 5.0'
require 'minitest/autorun'
require 'minitest/pride'
require 'minitest/mock'
require_relative '../lib/mutation_tester'

class MutatorTest < Minitest::Test
  def setup
    @config = MutationTester::Configuration.new
    @config.mutation_types.transform_values! { |_| true }
  end

  def test_multi_line_string_replacement
    source = <<~RUBY
      def foo
        puts "Line 1
        Line 2"
      end
    RUBY

    Dir.mktmpdir do |dir|
      file_path = File.join(dir, 'test.rb')
      File.write(file_path, source)

      mutator = MutationTester::Mutator.new(file_path, @config)
      ast = Parser::CurrentRuby.parse(source)

      dstr_node = find_node(ast, :dstr)
      refute_nil(dstr_node, 'Should find dstr node')

      mutations = mutator.send(:mutate_string_node, dstr_node)
      assert_equal 1, mutations.size

      mutation = mutations.first
      assert_equal "''", mutation[:mutated]

      expected_code = <<~RUBY
        def foo
          puts ""
        end
      RUBY

      assert_equal expected_code.strip, mutation[:code].strip
    end
  end

  def test_interpolated_string_replacement
    source = <<~RUBY
      def foo(name)
        puts "Hello \#{name}"
      end
    RUBY

    Dir.mktmpdir do |dir|
      file_path = File.join(dir, 'test.rb')
      File.write(file_path, source)

      mutator = MutationTester::Mutator.new(file_path, @config)
      ast = Parser::CurrentRuby.parse(source)

      dstr_node = find_node(ast, :dstr)
      refute_nil(dstr_node, 'Should find dstr node')

      mutations = mutator.send(:mutate_string_node, dstr_node)
      assert_equal 1, mutations.size

      mutation = mutations.first
      assert_equal "''", mutation[:mutated]

      expected_code = <<~RUBY
        def foo(name)
          puts ""
        end
      RUBY

      assert_equal expected_code.strip, mutation[:code].strip
    end
  end

  def test_safe_unparse_error_handling
    source = 'def foo; end'
    Dir.mktmpdir do |dir|
      file_path = File.join(dir, 'test.rb')
      File.write(file_path, source)

      mutator = MutationTester::Mutator.new(file_path, @config)

      node = Parser::AST::Node.new(:dummy)

      Unparser.stub(:unparse, ->(_) { raise 'Unparser Error' }) do

        assert_raises(RuntimeError) do
          mutator.send(:safe_unparse, node)
        end
      end
    end
  end

  def test_multiline_logical_and_mutation
    source = "check(\n  a\n) && b\n"

    Dir.mktmpdir do |dir|
      file_path = File.join(dir, 'test.rb')
      File.write(file_path, source)

      mutator = MutationTester::Mutator.new(file_path, @config)
      ast = Parser::CurrentRuby.parse(source)

      and_node = find_node(ast, :and)
      refute_nil(and_node, 'Should find and node')

      mutations = mutator.send(:mutate_logical_and, and_node)
      assert_equal 3, mutations.size, 'Multiline && must generate a swap plus two operand removals'

      mutation = mutations.first
      assert_equal '||', mutation[:mutated]

      code = mutation[:code]
      assert_includes code, '||', 'Mutated code should contain ||'
      refute_includes code, '&&', 'Original && should be gone'
      assert_match(/\)\s*\|\|\s*b/, code, '|| must land at the operator position')

      mutations.each { |m| refute_nil Parser::CurrentRuby.parse(m[:code]) }
    end
  end

  def test_single_line_logical_and_mutation
    source = "a && b\n"

    Dir.mktmpdir do |dir|
      file_path = File.join(dir, 'test.rb')
      File.write(file_path, source)

      mutator = MutationTester::Mutator.new(file_path, @config)
      ast = Parser::CurrentRuby.parse(source)

      and_node = find_node(ast, :and)
      mutations = mutator.send(:mutate_logical_and, and_node)

      assert_equal 3, mutations.size
      assert_equal ["a || b\n", "a\n", "b\n"], mutations.map { |m| m[:code] }
      mutations.each { |m| refute_nil Parser::CurrentRuby.parse(m[:code]) }
    end
  end

  def test_logical_and_broken_after_operator
    source = "a &&\n  b\n"

    Dir.mktmpdir do |dir|
      file_path = File.join(dir, 'test.rb')
      File.write(file_path, source)

      mutator = MutationTester::Mutator.new(file_path, @config)
      ast = Parser::CurrentRuby.parse(source)

      and_node = find_node(ast, :and)
      mutations = mutator.send(:mutate_logical_and, and_node)

      assert_equal 3, mutations.size
      code = mutations.first[:code]
      assert_match(/a \|\|/, code)
      refute_includes code, '&&'
      mutations.each { |m| refute_nil Parser::CurrentRuby.parse(m[:code]) }
    end
  end

  def test_logical_or_mutation
    source = "a || b\n"

    Dir.mktmpdir do |dir|
      file_path = File.join(dir, 'test.rb')
      File.write(file_path, source)

      mutator = MutationTester::Mutator.new(file_path, @config)
      ast = Parser::CurrentRuby.parse(source)

      or_node = find_node(ast, :or)
      mutations = mutator.send(:mutate_logical_or, or_node)

      assert_equal 3, mutations.size
      assert_equal ["a && b\n", "a\n", "b\n"], mutations.map { |m| m[:code] }
      mutations.each { |m| refute_nil Parser::CurrentRuby.parse(m[:code]) }
    end
  end

  def test_generation_error_emits_warning_and_counts_skip
    @config.verbose = true
    source = "flag = true\n"

    Dir.mktmpdir do |dir|
      file_path = File.join(dir, 'test.rb')
      File.write(file_path, source)

      mutator = MutationTester::Mutator.new(file_path, @config)
      ast = Parser::CurrentRuby.parse(source)
      true_node = find_node(ast, :true)
      refute_nil true_node

      out, _err = capture_io do
        Unparser.stub(:unparse, ->(*) { raise 'boom' }) do
          result = mutator.send(:mutate_boolean_node, true_node)
          assert_empty result
        end
      end

      assert_match(/boolean/, out, 'Warning must mention the mutation type')
      assert_match(/#{Regexp.escape(file_path)}:1/, out, 'Warning must include file:line')
      assert_equal 1, mutator.skipped_count
    end
  end

  def test_generation_error_respects_verbose_false
    @config.verbose = false
    source = "flag = true\n"

    Dir.mktmpdir do |dir|
      file_path = File.join(dir, 'test.rb')
      File.write(file_path, source)

      mutator = MutationTester::Mutator.new(file_path, @config)
      ast = Parser::CurrentRuby.parse(source)
      true_node = find_node(ast, :true)

      out, err = capture_io do
        Unparser.stub(:unparse, ->(*) { raise 'boom' }) do
          mutator.send(:mutate_boolean_node, true_node)
        end
      end

      assert_empty(out + err, 'No warning should be printed when verbose is false')
      assert_equal 1, mutator.skipped_count, 'Skips are still counted when quiet'
    end
  end

  def test_generation_reports_skipped_count
    source = "flag = true\n"

    Dir.mktmpdir do |dir|
      file_path = File.join(dir, 'test.rb')
      File.write(file_path, source)

      mutator = MutationTester::Mutator.new(file_path, @config)
      ast = Parser::CurrentRuby.parse(source)

      out, _err = capture_io do
        Unparser.stub(:unparse, ->(*) { raise 'boom' }) do
          mutator.generate_mutations(ast)
        end
      end

      assert_match(/skipped 1/, out, 'Summary should report the skipped count')
      assert_equal 1, mutator.skipped_count
    end
  end

  def test_literal_zero_produces_single_change_to_one
    source = "x = 0\n"

    Dir.mktmpdir do |dir|
      file_path = File.join(dir, 'test.rb')
      File.write(file_path, source)

      mutator = MutationTester::Mutator.new(file_path, @config)
      ast = Parser::CurrentRuby.parse(source)

      mutations = mutator.generate_mutations(ast)
      zero_to_one = mutations.select do |m|
        m[:type] == :number && m[:original] == '0' && m[:mutated] == '1'
      end

      assert_equal 1, zero_to_one.size, 'Exactly one mutant should change 0 to 1'
      assert_equal "x = 1\n", zero_to_one.first[:code]
    end
  end

  def test_noop_mutants_are_rejected
    source = "flag = true\n"

    Dir.mktmpdir do |dir|
      file_path = File.join(dir, 'test.rb')
      File.write(file_path, source)

      mutator = MutationTester::Mutator.new(file_path, @config)
      ast = Parser::CurrentRuby.parse(source)

      mutator.stub(:replace_node, source) do
        mutations = mutator.generate_mutations(ast)
        refute_includes mutations.map { |m| m[:code] }, source
        assert_empty mutations, 'No-op mutants must be filtered out'
      end
    end
  end

  def test_no_duplicate_code_across_mutations
    source = "x = 0\ny = 2\nz = true\n"

    Dir.mktmpdir do |dir|
      file_path = File.join(dir, 'test.rb')
      File.write(file_path, source)

      mutator = MutationTester::Mutator.new(file_path, @config)
      ast = Parser::CurrentRuby.parse(source)

      codes = mutator.generate_mutations(ast).map { |m| m[:code] }
      assert_equal codes.uniq, codes, 'Mutated code must be unique across all mutations'
    end
  end

  def test_post_filter_count_and_gap_free_ids
    source = "x = 0\n"

    Dir.mktmpdir do |dir|
      file_path = File.join(dir, 'test.rb')
      File.write(file_path, source)

      mutator = MutationTester::Mutator.new(file_path, @config)
      ast = Parser::CurrentRuby.parse(source)

      raw = mutator.send(:collect_mutations, ast)
      mutations = mutator.generate_mutations(ast)

      assert_operator mutations.size, :<, raw.size, 'Filter should drop the duplicate'
      assert_equal mutations.map { |m| m[:code] }.uniq.size, mutations.size
      assert_equal((1..mutations.size).to_a, mutations.map { |m| m[:id] })
    end
  end

  def test_negated_comparison_condition_wraps_in_parentheses
    source = <<~RUBY
      def check(a)
        if a > 1
          :big
        else
          :small
        end
      end
    RUBY

    Dir.mktmpdir do |dir|
      file_path = File.join(dir, 'test.rb')
      File.write(file_path, source)

      mutator = MutationTester::Mutator.new(file_path, @config)
      ast = Parser::CurrentRuby.parse(source)

      if_node = find_node(ast, :if)
      refute_nil(if_node, 'Should find if node')

      mutations = mutator.send(:mutate_conditional_node, if_node)
      assert_equal 1, mutations.size

      mutation = mutations.first
      assert_equal :conditional, mutation[:type]
      assert_includes mutation[:code], '!(a > 1)'
      refute_includes mutation[:code], '!a > 1'
      assert_equal '!(a > 1)', mutation[:mutated]
    end
  end

  def test_negated_comparison_condition_runs_without_error
    source = <<~RUBY
      def check(a)
        if a > 1
          :big
        else
          :small
        end
      end
    RUBY

    Dir.mktmpdir do |dir|
      file_path = File.join(dir, 'test.rb')
      File.write(file_path, source)

      mutator = MutationTester::Mutator.new(file_path, @config)
      ast = Parser::CurrentRuby.parse(source)

      if_node = find_node(ast, :if)
      mutation = mutator.send(:mutate_conditional_node, if_node).first

      refute_nil Parser::CurrentRuby.parse(mutation[:code])

      klass = Class.new
      klass.class_eval(mutation[:code])
      assert_equal :small, klass.new.check(5)
    end
  end

  def test_keyword_and_mutates_to_keyword_or
    source = "a and b\n"

    Dir.mktmpdir do |dir|
      file_path = File.join(dir, 'test.rb')
      File.write(file_path, source)

      mutator = MutationTester::Mutator.new(file_path, @config)
      ast = Parser::CurrentRuby.parse(source)

      and_node = find_node(ast, :and)
      mutation = mutator.send(:mutate_logical_and, and_node).first

      assert_equal "a or b\n", mutation[:code]
      assert_equal 'and', mutation[:original]
      assert_equal 'or', mutation[:mutated]
      assert_equal 'Change and to or', mutation[:description]
      refute_nil Parser::CurrentRuby.parse(mutation[:code])
    end
  end

  def test_keyword_or_mutates_to_keyword_and
    source = "a or b\n"

    Dir.mktmpdir do |dir|
      file_path = File.join(dir, 'test.rb')
      File.write(file_path, source)

      mutator = MutationTester::Mutator.new(file_path, @config)
      ast = Parser::CurrentRuby.parse(source)

      or_node = find_node(ast, :or)
      mutation = mutator.send(:mutate_logical_or, or_node).first

      assert_equal "a and b\n", mutation[:code]
      assert_equal 'or', mutation[:original]
      assert_equal 'and', mutation[:mutated]
      assert_equal 'Change or to and', mutation[:description]
      refute_nil Parser::CurrentRuby.parse(mutation[:code])
    end
  end

  def test_symbol_and_fields_are_symbolic
    source = "a && b\n"

    Dir.mktmpdir do |dir|
      file_path = File.join(dir, 'test.rb')
      File.write(file_path, source)

      mutator = MutationTester::Mutator.new(file_path, @config)
      ast = Parser::CurrentRuby.parse(source)

      and_node = find_node(ast, :and)
      mutation = mutator.send(:mutate_logical_and, and_node).first

      assert_equal '&&', mutation[:original]
      assert_equal '||', mutation[:mutated]
      assert_equal 'Change && to ||', mutation[:description]
    end
  end

  def test_multiline_symbol_or_mutates_to_and
    source = "check(\n  a\n) || b\n"

    Dir.mktmpdir do |dir|
      file_path = File.join(dir, 'test.rb')
      File.write(file_path, source)

      mutator = MutationTester::Mutator.new(file_path, @config)
      ast = Parser::CurrentRuby.parse(source)

      or_node = find_node(ast, :or)
      mutation = mutator.send(:mutate_logical_or, or_node).first

      assert_equal "check(\n  a\n) && b\n", mutation[:code]
      assert_equal '||', mutation[:original]
      assert_equal '&&', mutation[:mutated]
      refute_nil Parser::CurrentRuby.parse(mutation[:code])
    end
  end

  def test_loader_string_arguments_are_not_mutated
    {
      'require' => 'require "json"',
      'require_relative' => 'require_relative "helper"',
      'load' => 'load "config.rb"',
      'autoload' => 'autoload :Foo, "foo/bar"'
    }.each do |loader, source|
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, 'test.rb')
        File.write(file_path, source + "\n")

        mutator = MutationTester::Mutator.new(file_path, @config)
        ast = Parser::CurrentRuby.parse(source)

        strings = mutator.generate_mutations(ast).select { |m| m[:type] == :string }
        assert_empty strings, "#{loader} string argument should not be mutated"
      end
    end
  end

  def test_regular_string_still_mutated
    source = "def greeting\n  \"hello\"\nend\n"

    Dir.mktmpdir do |dir|
      file_path = File.join(dir, 'test.rb')
      File.write(file_path, source)

      mutator = MutationTester::Mutator.new(file_path, @config)
      ast = Parser::CurrentRuby.parse(source)

      strings = mutator.generate_mutations(ast).select { |m| m[:type] == :string }
      assert_equal 1, strings.size
      assert_equal "''", strings.first[:mutated]
      assert_equal "def greeting\n  \"\"\nend\n", strings.first[:code]
    end
  end

  def test_skipped_require_string_does_not_count_as_skip
    source = %(require_relative "helper"\n)

    Dir.mktmpdir do |dir|
      file_path = File.join(dir, 'test.rb')
      File.write(file_path, source)

      mutator = MutationTester::Mutator.new(file_path, @config)
      ast = Parser::CurrentRuby.parse(source)

      mutator.generate_mutations(ast)
      assert_equal 0, mutator.skipped_count
    end
  end

  def test_heredoc_produces_no_string_mutant_and_no_orphaned_body
    { '<<~TEXT' => 'squiggly', '<<-TEXT' => 'dash', '<<TEXT' => 'plain' }.each do |marker, label|
      source = "def banner\n  msg = #{marker}\n    hello\n    world\nTEXT\n  msg\nend\n"

      Dir.mktmpdir do |dir|
        file_path = File.join(dir, 'test.rb')
        File.write(file_path, source)

        mutator = MutationTester::Mutator.new(file_path, @config)
        ast = Parser::CurrentRuby.parse(source)

        mutations = mutator.generate_mutations(ast)
        strings = mutations.select { |m| m[:type] == :string }
        assert_empty strings, "#{label} heredoc should not produce a string mutant"
        mutations.each do |mutation|
          refute_nil Parser::CurrentRuby.parse(mutation[:code]),
                     "#{label} heredoc mutant must stay parseable"
        end
      end
    end
  end

  def test_regular_string_beside_heredoc_still_mutates
    source = "def banner\n  note = \"hi\"\n  msg = <<~TEXT\n    hello\n  TEXT\n  [note, msg]\nend\n"

    Dir.mktmpdir do |dir|
      file_path = File.join(dir, 'test.rb')
      File.write(file_path, source)

      mutator = MutationTester::Mutator.new(file_path, @config)
      ast = Parser::CurrentRuby.parse(source)

      strings = mutator.generate_mutations(ast).select { |m| m[:type] == :string }
      assert_equal 1, strings.size
      assert_equal "''", strings.first[:mutated]
      assert_includes strings.first[:code], 'note = ""'
      assert_includes strings.first[:code], '<<~TEXT'
    end
  end

  def test_skipped_heredoc_does_not_count_as_skip
    source = "def banner\n  <<~TEXT\n    hello\n  TEXT\nend\n"

    Dir.mktmpdir do |dir|
      file_path = File.join(dir, 'test.rb')
      File.write(file_path, source)

      mutator = MutationTester::Mutator.new(file_path, @config)
      ast = Parser::CurrentRuby.parse(source)

      mutator.generate_mutations(ast)
      assert_equal 0, mutator.skipped_count
    end
  end

  def test_op_asgn_operator_mutated_to_minus_times_divide
    source = "a += 2\n"

    Dir.mktmpdir do |dir|
      file_path = File.join(dir, 'test.rb')
      File.write(file_path, source)

      mutator = MutationTester::Mutator.new(file_path, @config)
      ast = Parser::CurrentRuby.parse(source)

      ops = mutator.generate_mutations(ast).select { |m| m[:original] == '+=' }

      assert_equal %w[-= *= /=].sort, ops.map { |m| m[:mutated] }.sort
      assert_equal ["a -= 2\n", "a *= 2\n", "a /= 2\n"].sort, ops.map { |m| m[:code] }.sort
      ops.each { |m| refute_nil Parser::CurrentRuby.parse(m[:code]), 'op_asgn mutant must parse' }
    end
  end

  def test_op_asgn_keeps_number_mutants_without_duplication
    source = "a += 2\n"

    Dir.mktmpdir do |dir|
      file_path = File.join(dir, 'test.rb')
      File.write(file_path, source)

      mutator = MutationTester::Mutator.new(file_path, @config)
      ast = Parser::CurrentRuby.parse(source)

      mutations = mutator.generate_mutations(ast)
      numbers = mutations.select { |m| m[:type] == :number }

      assert_equal ["a += 0\n", "a += 1\n", "a += 3\n"].sort, numbers.map { |m| m[:code] }.sort
      codes = mutations.map { |m| m[:code] }
      assert_equal codes.uniq, codes, 'No duplicate mutated code'
      assert_equal((1..mutations.size).to_a, mutations.map { |m| m[:id] })
    end
  end

  def test_not_equal_is_symmetric_to_equal
    source = "a != b\n"

    Dir.mktmpdir do |dir|
      file_path = File.join(dir, 'test.rb')
      File.write(file_path, source)

      mutator = MutationTester::Mutator.new(file_path, @config)
      ast = Parser::CurrentRuby.parse(source)

      comparisons = mutator.generate_mutations(ast).select { |m| m[:type] == :comparison }
      mutated = comparisons.map { |m| m[:mutated] }

      %w[== > <].each { |op| assert_includes mutated, op, "!= should also mutate to #{op}" }
      ["a == b\n", "a > b\n", "a < b\n"].each do |code|
        assert_includes comparisons.map { |m| m[:code] }, code
      end
      comparisons.each { |m| refute_nil Parser::CurrentRuby.parse(m[:code]) }
    end
  end

  def test_boolean_mutant_still_generated_both_directions
    source = "a = true\nb = false\n"

    Dir.mktmpdir do |dir|
      file_path = File.join(dir, 'test.rb')
      File.write(file_path, source)

      mutator = MutationTester::Mutator.new(file_path, @config)
      ast = Parser::CurrentRuby.parse(source)

      boolean = mutator.generate_mutations(ast).select { |m| m[:type] == :boolean }
      true_to_false = boolean.find { |m| m[:original] == 'true' }
      false_to_true = boolean.find { |m| m[:original] == 'false' }

      refute_nil true_to_false, 'true -> false boolean mutant must be generated'
      assert_equal 'false', true_to_false[:mutated]
      assert_equal "a = false\nb = false\n", true_to_false[:code]
      assert_equal 'a = false', true_to_false[:mutated_line]
      assert_equal 'Change true to false', true_to_false[:description]

      refute_nil false_to_true, 'false -> true boolean mutant must be generated'
      assert_equal 'true', false_to_true[:mutated]
      assert_equal "a = true\nb = true\n", false_to_true[:code]
      assert_equal 'b = true', false_to_true[:mutated_line]
      assert_equal 'Change false to true', false_to_true[:description]
    end
  end

  private

  def find_node(node, type)
    return node if node.type == type
    node.children.each do |child|
      if child.is_a?(Parser::AST::Node)
        found = find_node(child, type)
        return found if found
      end
    end
    nil
  end
end
