module MutationTester
  class Mutator
    MUTATIONS = {
      arithmetic: {
        :+ => %i[- * /],
        :- => %i[+ * /],
        :* => %i[+ - /],
        :/ => %i[+ - *],
        :% => %i[+ - *],
        :** => %i[* +]
      },
      comparison: {
        :> => %i[< >= <= ==],
        :< => %i[> >= <= ==],
        :>= => %i[< > <= ==],
        :<= => %i[> >= < ==],
        :== => %i[!= > <],
        :!= => %i[== > <],
        :<=> => [:==]
      },
      bitwise: {
        :| => %i[&],
        :& => %i[|],
        :^ => %i[| &]
      },
      strict_equality: {
        :== => %i[eql? equal?]
      }
    }.freeze

    REQUIRE_METHODS = %i[require require_relative load autoload].freeze

    PURE_TRANSFORMATIONS = %i[
      uniq compact sort flatten strip chomp downcase upcase capitalize
      reverse round floor ceil abs to_a
    ].freeze

    BLOCK_NODE_TYPES = %i[block numblock itblock].freeze

    PLAIN_METHOD_NAME = /\A[A-Za-z_][A-Za-z0-9_]*[?!]?\z/.freeze

    NON_MUTABLE_ARGUMENT_TYPES = %i[block_pass splat kwsplat].freeze

    HASH_NODE_TYPES = %i[hash kwargs].freeze

    RANGE_OPERATOR_SWAPS = { irange: '...', erange: '..' }.freeze

    DISABLE_ANNOTATION = /mutation_tester:disable\b/.freeze

    def self.disabled_lines(content)
      _ast, comments = Parser::CurrentRuby.parse_with_comments(content)
      comments
        .select { |comment| comment.text.match?(DISABLE_ANNOTATION) }
        .map { |comment| comment.location.line }
        .uniq
    rescue Parser::SyntaxError
      []
    end

    attr_reader :skipped_count, :excluded_count

    def initialize(source_file, config = MutationTester.configuration)
      @source_file = source_file
      @config = config
      @original_content = File.read(source_file)
      @mutation_id = 0
      @skipped_count = 0
      @excluded_count = 0
      @disabled_lines = []
    end

    def generate_mutations(ast)
      @skipped_count = 0
      @excluded_count = 0
      @disabled_lines = self.class.disabled_lines(@original_content)
      @in_memory_safe_context = false
      @class_body_block_depth = 0
      mutations = collect_mutations(ast)
      mutations = filter_mutations(mutations)
      report_skipped(mutations.size) if @skipped_count.positive?
      mutations
    end

    private

    def filter_mutations(mutations)
      seen = {}
      filtered = []
      mutations.each do |mutation|
        if @disabled_lines.include?(mutation[:line])
          @excluded_count += 1
          next
        end

        code = mutation[:code]
        next if code == @original_content
        next if seen[code]

        seen[code] = true
        filtered << mutation
      end
      renumber_mutations(filtered)
    end

    def renumber_mutations(mutations)
      mutations.each_with_index { |mutation, index| mutation[:id] = index + 1 }
      mutations
    end

    def collect_mutations(ast, skip_string_mutation: false, block_call: false)
      mutations = []
      previous_safe = @in_memory_safe_context
      previous_block_depth = @class_body_block_depth
      return mutations unless ast

      scope_name = method_scope_name(ast)
      previous_scope = @enclosing_method
      @enclosing_method = scope_name if scope_name
      update_load_time_context(ast.type)

      case ast.type
      when :send
        mutations += mutate_send_node(ast) if enabled?(:arithmetic) || enabled?(:comparison) || enabled?(:logical) || enabled?(:strict_equality)
        mutations += mutate_call_removal_node(ast) if enabled?(:call_removal) && !block_call
        mutations += mutate_argument_node(ast) if enabled?(:argument)
      when :def, :defs
        mutations += mutate_method_return_node(ast) if enabled?(:nil_injection)
        mutations += mutate_default_value_node(ast) if enabled?(:argument)
      when :ivasgn
        mutations += mutate_ivasgn_node(ast) if enabled?(:nil_injection)
      when :true, :false
        mutations += mutate_boolean_node(ast) if enabled?(:boolean)
      when :if, :while, :until, :while_post, :until_post
        mutations += mutate_conditional_node(ast) if enabled?(:conditional)
      when :case
        mutations += mutate_case_node(ast) if enabled?(:conditional)
      when :op_asgn
        mutations += mutate_op_asgn_node(ast) if enabled?(:arithmetic)
      when :or_asgn
        mutations += mutate_or_asgn_node(ast) if enabled?(:logical)
      when :and_asgn
        mutations += mutate_and_asgn_node(ast) if enabled?(:logical)
      when :int, :float
        mutations += mutate_number_node(ast) if enabled?(:number)
      when :str, :dstr
        mutations += mutate_string_node(ast) if enabled?(:string) && !skip_string_mutation && !heredoc_node?(ast)
      when :and
        mutations += mutate_logical_and(ast) if enabled?(:logical)
      when :or
        mutations += mutate_logical_or(ast) if enabled?(:logical)
      when :irange, :erange
        mutations += mutate_range_node(ast) if enabled?(:comparison)
      end

      mutations.each do |mutation|
        mutation[:method_name] = @enclosing_method
        mutation[:in_memory_safe] = @in_memory_safe_context
      end

      loader_call = require_like_send?(ast)
      heredoc = heredoc_node?(ast)
      ast.children.each do |child|
        next unless child.is_a?(Parser::AST::Node)

        child_skips_string =
          skip_string_mutation || heredoc || (loader_call && string_literal?(child))
        child_is_block_call = BLOCK_NODE_TYPES.include?(ast.type) && child.equal?(ast.children[0])
        mutations += collect_mutations(child, skip_string_mutation: child_skips_string, block_call: child_is_block_call)
      end

      mutations
    ensure
      @enclosing_method = previous_scope if scope_name
      @in_memory_safe_context = previous_safe
      @class_body_block_depth = previous_block_depth
    end

    def update_load_time_context(type)
      case type
      when :class, :module, :sclass
        @in_memory_safe_context = false
      when :def, :defs
        @in_memory_safe_context = true if @class_body_block_depth.zero?
      else
        @class_body_block_depth += 1 if BLOCK_NODE_TYPES.include?(type) && !@in_memory_safe_context
      end
    end

    def method_scope_name(node)
      case node.type
      when :def then node.children[0].to_s
      when :defs then node.children[1].to_s
      end
    end

    def require_like_send?(node)
      node.type == :send && node.children[0].nil? && REQUIRE_METHODS.include?(node.children[1])
    end

    def string_literal?(node)
      node.type == :str || node.type == :dstr
    end

    def heredoc_node?(node)
      loc = node.loc
      loc.respond_to?(:heredoc_body) && !loc.heredoc_body.nil?
    end

    def warn_skipped(type, node, error)
      @skipped_count += 1
      return unless @config.verbose

      line = node.loc&.line
      location = "#{@source_file}:#{line}"
      puts Rainbow("Warning: skipped #{type} mutation at #{location} - #{error.message}").yellow
    end

    def report_skipped(generated)
      puts Rainbow("Generated #{generated} mutations, skipped #{@skipped_count}").yellow
    end

    def enabled?(type)
      @config.mutation_types[type]
    end

    def mutate_send_node(node)
      mutations = []
      method_name = node.children[1]

      if enabled?(:arithmetic) && MUTATIONS[:arithmetic][method_name]
        MUTATIONS[:arithmetic][method_name].each do |replacement|
          mutations << create_mutation(node, replacement, :arithmetic)
        end
      end

      if enabled?(:comparison) && MUTATIONS[:comparison][method_name]
        MUTATIONS[:comparison][method_name].each do |replacement|
          mutations << create_mutation(node, replacement, :comparison)
        end
      end

      if enabled?(:strict_equality) && MUTATIONS[:strict_equality][method_name] && strict_equality_candidate?(node)
        MUTATIONS[:strict_equality][method_name].each do |replacement|
          mutations << create_mutation(node, replacement, :strict_equality)
        end
      end

      mutations
    rescue => e
      warn_skipped(:send, node, e)
      []
    end

    def strict_equality_candidate?(node)
      node.children[0].is_a?(Parser::AST::Node) && node.children.size == 3
    end

    def mutate_call_removal_node(node)
      receiver, method_name, *arguments = node.children
      return [] unless receiver.is_a?(Parser::AST::Node)
      return [] unless arguments.empty?
      return [] unless PURE_TRANSFORMATIONS.include?(method_name)

      mutated_code = replace_node(node, receiver)
      return [] if mutated_code == @original_content
      return [] unless parses_cleanly?(mutated_code)

      [{
        id: next_mutation_id,
        type: :call_removal,
        line: node.loc.line,
        original: safe_unparse(node),
        mutated: safe_unparse(receiver),
        code: mutated_code,
        source_line: extract_source_line(node.loc.line),
        mutated_line: extract_mutated_line(mutated_code, node.loc.line),
        description: "Remove #{method_name} call"
      }]
    rescue => e
      warn_skipped(:call_removal, node, e)
      []
    end

    def mutate_argument_node(node)
      method_name = node.children[1]
      arguments = node.children[2..]
      return [] if arguments.empty?
      return [] unless PLAIN_METHOD_NAME.match?(method_name.to_s)
      return [] if REQUIRE_METHODS.include?(method_name)

      build_last_argument_removal(node, arguments) +
        build_argument_nil_mutations(node, arguments) +
        build_pair_removal_mutations(node, arguments)
    rescue => e
      warn_skipped(:argument, node, e)
      []
    end

    def mutable_argument?(argument)
      return false if NON_MUTABLE_ARGUMENT_TYPES.include?(argument.type)
      return false if %i[kwargs hash].include?(argument.type) &&
                      argument.children.any? { |child| child.is_a?(Parser::AST::Node) && child.type == :kwsplat }

      true
    end

    def build_last_argument_removal(node, arguments)
      last = arguments.last
      return [] unless mutable_argument?(last)

      range_begin, range_end =
        if arguments.size > 1
          [arguments[-2].loc.expression.end_pos, last.loc.expression.end_pos]
        elsif node.loc.begin
          [node.loc.begin.end_pos, node.loc.end.begin_pos]
        else
          [node.loc.selector.end_pos, last.loc.expression.end_pos]
        end

      mutation = build_argument_mutation(
        node, range_begin, range_end, '',
        "Remove last argument from #{node.children[1]}"
      )
      mutation ? [mutation] : []
    end

    def build_argument_nil_mutations(node, arguments)
      arguments.filter_map do |argument|
        next if !mutable_argument?(argument) || argument.type == :nil

        expression = argument.loc.expression
        build_argument_mutation(
          node, expression.begin_pos, expression.end_pos, 'nil',
          "Replace argument #{source_slice(expression.begin_pos, expression.end_pos)} with nil"
        )
      end
    end

    def build_pair_removal_mutations(node, arguments)
      arguments.flat_map do |argument|
        next [] unless HASH_NODE_TYPES.include?(argument.type)
        next [] if contains_heredoc?(argument)

        build_hash_pair_removals(node, argument)
      end
    end

    def build_hash_pair_removals(node, hash)
      return [] unless mutable_argument?(hash)

      pairs = hash.children
      nested = pairs.flat_map do |pair|
        value = pair.children[1]
        value.type == :hash ? build_hash_pair_removals(node, value) : []
      end

      pairs.each_index.filter_map { |index| build_pair_removal(node, hash, index) } + nested
    end

    def build_pair_removal(node, hash, index)
      range_begin, range_end = pair_removal_range(hash, index)
      return nil unless range_begin

      key = hash.children[index].children[0].loc.expression
      build_argument_mutation(
        node, range_begin, range_end, '',
        "Remove pair #{source_slice(key.begin_pos, key.end_pos)} from #{node.children[1]}"
      )
    end

    def pair_removal_range(hash, index)
      pairs = hash.children
      pair = pairs[index].loc.expression

      if pairs.size == 1
        return nil unless hash.loc.begin

        [hash.loc.begin.end_pos, hash.loc.end.begin_pos]
      elsif index < pairs.size - 1
        [pair.begin_pos, pairs[index + 1].loc.expression.begin_pos]
      else
        [pairs[index - 1].loc.expression.end_pos, pair.end_pos]
      end
    end

    def contains_heredoc?(node)
      return false unless node.is_a?(Parser::AST::Node)

      heredoc_node?(node) || node.children.any? { |child| contains_heredoc?(child) }
    end

    def build_argument_mutation(node, range_begin, range_end, replacement, description)
      mutated_code = splice_source(range_begin, range_end, replacement)
      return nil if mutated_code == @original_content
      return nil unless parses_cleanly?(mutated_code)

      call = node.loc.expression
      offset = replacement.length - (range_end - range_begin)
      {
        id: next_mutation_id,
        type: :argument,
        line: node.loc.line,
        original: source_slice(call.begin_pos, call.end_pos),
        mutated: mutated_code[call.begin_pos...(call.end_pos + offset)],
        code: mutated_code,
        source_line: extract_source_line(node.loc.line),
        mutated_line: extract_mutated_line(mutated_code, node.loc.line),
        description: description
      }
    end

    def mutate_default_value_node(node)
      args = node.type == :def ? node.children[1] : node.children[2]
      return [] unless args.is_a?(Parser::AST::Node)

      params = args.children.grep(Parser::AST::Node)
      optional_before_required = optional_before_required?(params)

      params.flat_map do |param|
        next [] unless %i[optarg kwoptarg].include?(param.type)

        skip_removal = param.type == :optarg && optional_before_required
        build_default_removal(param, skip: skip_removal) + build_default_nil(param)
      end
    rescue => e
      warn_skipped(:argument, node, e)
      []
    end

    def optional_before_required?(params)
      optarg_seen = false
      params.any? do |param|
        optarg_seen = true if param.type == :optarg
        optarg_seen && param.type == :arg
      end
    end

    def build_default_removal(param, skip:)
      return [] if skip

      name = param.children[0]
      range_begin = param.loc.name.end_pos
      range_begin += 1 if param.type == :kwoptarg
      mutation = build_default_value_mutation(
        param, range_begin, param.loc.expression.end_pos, '',
        "Remove default value of #{name}"
      )
      mutation ? [mutation] : []
    end

    def build_default_nil(param)
      value = param.children[1]
      return [] if %i[nil false].include?(value.type)

      expression = value.loc.expression
      mutation = build_default_value_mutation(
        param, expression.begin_pos, expression.end_pos, 'nil',
        "Replace default value of #{param.children[0]} with nil"
      )
      mutation ? [mutation] : []
    end

    def build_default_value_mutation(param, range_begin, range_end, replacement, description)
      mutated_code = splice_source(range_begin, range_end, replacement)
      return nil if mutated_code == @original_content
      return nil unless parses_cleanly?(mutated_code)

      expression = param.loc.expression
      offset = replacement.length - (range_end - range_begin)
      {
        id: next_mutation_id,
        type: :argument,
        line: param.loc.line,
        original: source_slice(expression.begin_pos, expression.end_pos),
        mutated: mutated_code[expression.begin_pos...(expression.end_pos + offset)],
        code: mutated_code,
        source_line: extract_source_line(param.loc.line),
        mutated_line: extract_mutated_line(mutated_code, param.loc.line),
        description: description
      }
    end

    def splice_source(range_begin, range_end, replacement)
      code = @original_content.dup
      code[range_begin...range_end] = replacement
      code
    end

    def source_slice(range_begin, range_end)
      @original_content[range_begin...range_end]
    end

    def mutate_method_return_node(node)
      body = node.type == :def ? node.children[2] : node.children[3]
      return [] unless body.is_a?(Parser::AST::Node)
      return [] if %i[rescue ensure].include?(body.type)

      last_expression = body.type == :begin ? body.children.last : body
      return [] unless last_expression.is_a?(Parser::AST::Node)
      return [] if last_expression.type == :nil

      build_nil_injection_mutation(last_expression, 'Replace method return value with nil')
    rescue => e
      warn_skipped(:nil_injection, node, e)
      []
    end

    def mutate_ivasgn_node(node)
      name, value = node.children
      return [] unless value.is_a?(Parser::AST::Node)
      return [] if value.type == :nil

      build_nil_injection_mutation(value, "Assign nil to #{name}")
    rescue => e
      warn_skipped(:nil_injection, node, e)
      []
    end

    def build_nil_injection_mutation(target, description)
      mutated_code = replace_node(target, Parser::AST::Node.new(:nil))
      return [] if mutated_code == @original_content
      return [] unless parses_cleanly?(mutated_code)

      [{
        id: next_mutation_id,
        type: :nil_injection,
        line: target.loc.line,
        original: safe_unparse(target),
        mutated: 'nil',
        code: mutated_code,
        source_line: extract_source_line(target.loc.line),
        mutated_line: extract_mutated_line(mutated_code, target.loc.line),
        description: description
      }]
    end

    def mutate_op_asgn_node(node)
      operator = node.children[1]
      replacements = MUTATIONS[:arithmetic][operator] || MUTATIONS[:bitwise][operator]
      return [] unless replacements

      replacements.map { |replacement| create_op_asgn_mutation(node, operator, replacement) }
    rescue => e
      warn_skipped(:op_asgn, node, e)
      []
    end

    def mutate_logical_and(node)
      build_logical_mutation(node, :or) + build_operand_removal_mutations(node)
    end

    def mutate_logical_or(node)
      build_logical_mutation(node, :and) + build_operand_removal_mutations(node)
    end

    def build_operand_removal_mutations(node)
      operator = logical_operator_token(node)
      left, right = node.children

      [[left, right], [right, left]].filter_map do |kept, removed|
        mutated_code = replace_node(node, kept)
        next if mutated_code == @original_content
        next unless parses_cleanly?(mutated_code)

        {
          id: next_mutation_id,
          type: :logical,
          line: node.loc.line,
          original: safe_unparse(node),
          mutated: safe_unparse(kept),
          code: mutated_code,
          source_line: extract_source_line(node.loc.line),
          mutated_line: extract_mutated_line(mutated_code, node.loc.line),
          description: "Remove operand #{safe_unparse(removed)} from #{operator}"
        }
      end
    rescue => e
      warn_skipped(:logical, node, e)
      []
    end

    def logical_operator_token(node)
      operator_loc = node.loc&.operator
      return operator_loc.source if operator_loc

      node.type == :and ? '&&' : '||'
    end

    def mutate_or_asgn_node(node)
      build_op_asgn_logical_mutation(node, '&&=')
    end

    def mutate_and_asgn_node(node)
      build_op_asgn_logical_mutation(node, '||=')
    end

    def build_op_asgn_logical_mutation(node, mutated_operator)
      operator_loc = node.loc&.operator
      return [] unless operator_loc

      lines = @original_content.lines
      line_index = operator_loc.line - 1
      return [] if line_index >= lines.size

      start_col = operator_loc.column
      end_col = operator_loc.last_column
      original_operator = lines[line_index][start_col...end_col]

      line = lines[line_index].dup
      line[start_col...end_col] = mutated_operator
      lines[line_index] = line
      mutated_code = lines.join

      [{
        id: next_mutation_id,
        type: :logical,
        line: node.loc.line,
        original: original_operator,
        mutated: mutated_operator,
        code: mutated_code,
        source_line: extract_source_line(node.loc.line),
        mutated_line: extract_mutated_line(mutated_code, node.loc.line),
        description: "Change #{original_operator} to #{mutated_operator}"
      }]
    rescue => e
      warn_skipped(:logical, node, e)
      []
    end

    def build_logical_mutation(node, target_type)
      mutated_code, original_operator, mutated_operator = replace_logical_node(node, target_type)
      return [] if mutated_code.nil?

      [{
        id: next_mutation_id,
        type: :logical,
        line: node.loc.line,
        original: original_operator,
        mutated: mutated_operator,
        code: mutated_code,
        source_line: extract_source_line(node.loc.line),
        mutated_line: extract_mutated_line(mutated_code, node.loc.line),
        description: "Change #{original_operator} to #{mutated_operator}"
      }]
    rescue => e
      warn_skipped(:logical, node, e)
      []
    end

    def mutate_boolean_node(node)
      mutations = []
      value = node.type == :true
      opposite = value ? :false : :true

      mutated_code = replace_node(node, Parser::AST::Node.new(opposite))
      mutations << {
        id: next_mutation_id,
        type: :boolean,
        line: node.loc.line,
        original: value.to_s,
        mutated: (!value).to_s,
        code: mutated_code,
        source_line: extract_source_line(node.loc.line),
        mutated_line: extract_mutated_line(mutated_code, node.loc.line),
        description: "Change #{value} to #{!value}"
      }

      mutations
    rescue => e
      warn_skipped(:boolean, node, e)
      []
    end

    def mutate_conditional_node(node)
      mutations = []
      condition = node.children[0]

      if condition
        negated = negate_condition(condition)
        mutated_code = replace_node(condition, negated)
        mutations << {
          id: next_mutation_id,
          type: :conditional,
          line: node.loc.line,
          original: safe_unparse(condition),
          mutated: safe_unparse(negated),
          code: mutated_code,
          source_line: extract_source_line(node.loc.line),
          mutated_line: extract_mutated_line(mutated_code, node.loc.line),
          description: 'Negate conditional expression'
        }
      end

      mutations
    rescue => e
      warn_skipped(:conditional, node, e)
      []
    end

    def mutate_case_node(node)
      mutations = []
      children = node.children

      (1...(children.size - 1)).each do |position|
        when_node = children[position]
        next unless when_node.is_a?(Parser::AST::Node) && when_node.type == :when

        remaining = children[0...position] + children[(position + 1)..-1]
        new_case = Parser::AST::Node.new(:case, remaining)
        mutated_code = replace_node(node, new_case)

        next if mutated_code == @original_content
        next unless parses_cleanly?(mutated_code)

        mutations << {
          id: next_mutation_id,
          type: :conditional,
          line: when_node.loc.line,
          original: extract_source_line(when_node.loc.line),
          mutated: 'removed',
          code: mutated_code,
          source_line: extract_source_line(when_node.loc.line),
          mutated_line: '(when branch removed)',
          description: 'Remove when branch'
        }
      end

      mutations
    rescue => e
      warn_skipped(:conditional, node, e)
      []
    end

    def mutate_range_node(node)
      upper_bound = node.children[1]
      return [] if upper_bound.nil? || infinity_constant?(upper_bound)

      operator = node.loc.operator
      replacement = RANGE_OPERATOR_SWAPS.fetch(node.type)
      mutated_code = splice_source(operator.begin_pos, operator.end_pos, replacement)
      return [] unless parses_cleanly?(mutated_code)

      [{
        id: next_mutation_id,
        type: :comparison,
        line: operator.line,
        original: operator.source,
        mutated: replacement,
        code: mutated_code,
        source_line: extract_source_line(operator.line),
        mutated_line: extract_mutated_line(mutated_code, operator.line),
        description: "Change #{operator.source} to #{replacement}"
      }]
    rescue => e
      warn_skipped(:comparison, node, e)
      []
    end

    def infinity_constant?(node)
      node.type == :const && node.children[1] == :INFINITY
    end

    def parses_cleanly?(code)
      buffer = Parser::Source::Buffer.new('(mutant-candidate)')
      buffer.source = code
      parser = Parser::CurrentRuby.new
      parser.diagnostics.all_errors_are_fatal = true
      parser.diagnostics.ignore_warnings = true
      parser.parse(buffer)
      true
    rescue Parser::SyntaxError
      false
    end

    def mutate_number_node(node)
      mutations = []
      value = node.children[0]

      mutations << create_number_mutation(node, 0, "Change #{value} to 0") if value != 0

      mutations << create_number_mutation(node, 1, "Change #{value} to 1") if value != 1

      mutations << create_number_mutation(node, value + 1, "Increment #{value} to #{value + 1}")

      mutations << create_number_mutation(node, value - 1, "Decrement #{value} to #{value - 1}")

      mutations
    rescue => e
      warn_skipped(:number, node, e)
      []
    end

    def mutate_string_node(node)
      mutations = []

      empty_node = Parser::AST::Node.new(:str, [''])

      original_repr = node.type == :str ? "'#{node.children[0]}'" : '"..."'

      mutated_code = replace_node(node, empty_node)
      mutations << {
        id: next_mutation_id,
        type: :string,
        line: node.loc.line,
        original: original_repr,
        mutated: "''",
        code: mutated_code,
        source_line: extract_source_line(node.loc.line),
        mutated_line: extract_mutated_line(mutated_code, node.loc.line),
        description: 'Change string to empty string'
      }

      mutations
    rescue => e
      warn_skipped(:string, node, e)
      []
    end

    def create_mutation(node, replacement, type)
      new_node = Parser::AST::Node.new(
        :send,
        [
          node.children[0],
          replacement,
          *node.children[2..-1]
        ]
      )

      mutated_code = replace_node(node, new_node)
      {
        id: next_mutation_id,
        type: type,
        line: node.loc.line,
        original: node.children[1].to_s,
        mutated: replacement.to_s,
        code: mutated_code,
        source_line: extract_source_line(node.loc.line),
        mutated_line: extract_mutated_line(mutated_code, node.loc.line),
        description: "Change #{node.children[1]} to #{replacement}"
      }
    end

    def create_op_asgn_mutation(node, operator, replacement)
      new_node = Parser::AST::Node.new(
        :op_asgn,
        [node.children[0], replacement, *node.children[2..-1]]
      )

      mutated_code = replace_node(node, new_node)
      original_operator = "#{operator}="
      mutated_operator = "#{replacement}="
      {
        id: next_mutation_id,
        type: :arithmetic,
        line: node.loc.line,
        original: original_operator,
        mutated: mutated_operator,
        code: mutated_code,
        source_line: extract_source_line(node.loc.line),
        mutated_line: extract_mutated_line(mutated_code, node.loc.line),
        description: "Change #{original_operator} to #{mutated_operator}"
      }
    end

    def create_number_mutation(node, new_value, description)
      new_node = Parser::AST::Node.new(node.type, [new_value])
      mutated_code = replace_node(node, new_node)
      {
        id: next_mutation_id,
        type: :number,
        line: node.loc.line,
        original: node.children[0].to_s,
        mutated: new_value.to_s,
        code: mutated_code,
        source_line: extract_source_line(node.loc.line),
        mutated_line: extract_mutated_line(mutated_code, node.loc.line),
        description: description
      }
    end

    def replace_node(old_node, new_node)
      return @original_content unless old_node.loc

      lines = @original_content.lines
      start_line = old_node.loc.line
      end_line = old_node.loc.last_line

      return @original_content if start_line > lines.size || end_line > lines.size

      start_index = start_line - 1
      end_index = end_line - 1

      new_code = safe_unparse(new_node)

      if start_line == end_line
        line = lines[start_index].dup
        start_col = old_node.loc.column
        end_col = old_node.loc.last_column
        line[start_col...end_col] = new_code
        lines[start_index] = line
      else
        prefix = lines[start_index][0...old_node.loc.column]
        suffix = lines[end_index][old_node.loc.last_column..-1]

        combined = prefix + new_code + suffix
        lines[start_index..end_index] = combined
      end

      lines.join
    end

    def replace_logical_node(old_node, target_type)
      operator_loc = old_node.loc&.operator
      return nil unless operator_loc

      lines = @original_content.lines
      line_index = operator_loc.line - 1
      return nil if line_index >= lines.size

      start_col = operator_loc.column
      end_col = operator_loc.last_column
      original_operator = lines[line_index][start_col...end_col]

      keyword = %w[and or].include?(original_operator)
      mutated_operator =
        if target_type == :and
          keyword ? 'and' : '&&'
        else
          keyword ? 'or' : '||'
        end

      line = lines[line_index].dup
      line[start_col...end_col] = mutated_operator
      lines[line_index] = line

      [lines.join, original_operator, mutated_operator]
    end

    def negate_condition(node)
      wrapped = Parser::AST::Node.new(:begin, [node])
      Parser::AST::Node.new(:send, [wrapped, :!])
    end

    def safe_unparse(node)
      Unparser.unparse(node)
    end

    def next_mutation_id
      @mutation_id += 1
    end

    def extract_source_line(line_number)
      lines = @original_content.lines
      return '' if line_number > lines.size || line_number < 1
      lines[line_number - 1].strip
    end

    def extract_mutated_line(mutated_code, line_number)
      lines = mutated_code.lines
      return '' if line_number > lines.size || line_number < 1
      lines[line_number - 1].strip
    end
  end
end
