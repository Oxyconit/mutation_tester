# frozen_string_literal: true

module MutationTester
  module MinitestLoadHook
    class << self
      def on_load(&block)
        return block.call if loaded?

        callbacks << block
        trace.enable unless trace.enabled?
      end

      private

      def loaded?
        return false unless defined?(::Minitest::AbstractReporter)

        ::Minitest.respond_to?(:register_plugin) && ::Minitest.respond_to?(:extensions) && !::Minitest.extensions.nil?
      end

      def callbacks
        @callbacks ||= []
      end

      def trace
        @trace ||= TracePoint.new(:end) do |point|
          next unless defined?(::Minitest) && point.self.equal?(::Minitest) && loaded?

          @trace.disable
          callbacks.shift.call until callbacks.empty?
        end
      end
    end
  end
end
