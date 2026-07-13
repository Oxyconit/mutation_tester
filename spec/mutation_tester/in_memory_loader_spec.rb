require 'spec_helper'
require 'tmpdir'

RSpec.describe MutationTester::InMemoryLoader do
  describe '.apply' do
    it 'redefines methods of an already loaded class in the current process' do
      described_class.apply(<<~RUBY, '(in_memory_loader_spec_apply)')
        class InMemoryLoaderApplyProbe
          def value
            :original
          end
        end
      RUBY

      described_class.apply(<<~RUBY, '(in_memory_loader_spec_apply)')
        class InMemoryLoaderApplyProbe
          def value
            :redefined
          end
        end
      RUBY

      expect(InMemoryLoaderApplyProbe.new.value).to eq(:redefined)
    ensure
      Object.send(:remove_const, :InMemoryLoaderApplyProbe) if defined?(InMemoryLoaderApplyProbe)
    end

    it 'silences the already-initialized-constant warning during the eval only' do
      described_class.apply("class InMemoryLoaderConstProbe\n  LIMIT = 5\nend\n", '(in_memory_loader_spec_const)')

      expect do
        described_class.apply("class InMemoryLoaderConstProbe\n  LIMIT = 4\nend\n", '(in_memory_loader_spec_const)')
      end.not_to output.to_stderr

      expect(InMemoryLoaderConstProbe::LIMIT).to eq(4)
    ensure
      Object.send(:remove_const, :InMemoryLoaderConstProbe) if defined?(InMemoryLoaderConstProbe)
    end

    it 'restores the previous $VERBOSE value even when the eval raises' do
      previous = $VERBOSE

      expect do
        described_class.apply("raise 'boom at load time'\n", '(in_memory_loader_spec_verbose)')
      end.to raise_error(RuntimeError, 'boom at load time')

      expect($VERBOSE).to eq(previous)
    end

    it 'evaluates the source in the context of the given file path' do
      expect do
        described_class.apply("raise 'located'\n", '/virtual/pricer.rb')
      end.to raise_error(RuntimeError) { |e| expect(e.backtrace.first).to start_with('/virtual/pricer.rb:1') }
    end
  end

  describe '.load_time_defined_guard?' do
    it 'flags a top-level defined? guard' do
      expect(described_class.load_time_defined_guard?("X = 1 unless defined?(X)\n")).to be(true)
    end

    it 'flags a defined? guard inside a class body' do
      source = <<~RUBY
        class Calc
          LIMIT = 5 unless defined?(Calc::LIMIT)
        end
      RUBY

      expect(described_class.load_time_defined_guard?(source)).to be(true)
    end

    it 'accepts defined? inside a method body' do
      source = <<~RUBY
        class Calc
          def limit
            defined?(LIMIT) ? LIMIT : 0
          end
        end
      RUBY

      expect(described_class.load_time_defined_guard?(source)).to be(false)
    end

    it 'accepts sources without defined?' do
      expect(described_class.load_time_defined_guard?("class Calc\n  LIMIT = 5\nend\n")).to be(false)
    end

    it 'returns false for unparseable sources' do
      expect(described_class.load_time_defined_guard?('def broken(; end')).to be(false)
    end
  end
end
