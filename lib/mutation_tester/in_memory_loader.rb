module MutationTester
  module InMemoryLoader
    def self.apply(source, path)
      previous = $VERBOSE
      $VERBOSE = nil
      eval(source, TOPLEVEL_BINDING, path)
    ensure
      $VERBOSE = previous
    end

    def self.load_time_defined_guard?(source)
      load_time_defined?(Parser::CurrentRuby.parse(source))
    rescue Parser::SyntaxError
      false
    end

    def self.load_time_defined?(node)
      return false unless node.is_a?(Parser::AST::Node)
      return true if node.type == :defined?
      return false if %i[def defs].include?(node.type)

      node.children.any? { |child| load_time_defined?(child) }
    end
  end
end
