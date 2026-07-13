require 'spec_helper'
require 'tmpdir'

RSpec.describe MutationTester::FrameworkDetector do
  describe '.detect (by filename)' do
    it 'detects rspec by the *_spec.rb suffix' do
      expect(described_class.detect('foo_spec.rb')).to eq(:rspec)
    end

    it 'detects minitest by the *_test.rb suffix' do
      expect(described_class.detect('foo_test.rb')).to eq(:minitest)
    end

    it 'detects minitest by the test_* prefix' do
      expect(described_class.detect('test_foo.rb')).to eq(:minitest)
    end

    it 'does not classify latest.rb as minitest by suffix alone' do
      Dir.mktmpdir do |dir|
        file = File.join(dir, 'latest.rb')
        File.write(file, "VERSION = '1.0.0'\n")
        expect(described_class.detect(file)).to eq(:rspec)
      end
    end
  end

  describe '.detect (by content when the filename is ambiguous)' do
    it 'defaults to rspec when nothing indicates minitest' do
      Dir.mktmpdir do |dir|
        file = File.join(dir, 'foo.rb')
        File.write(file, "puts 'hello'\n")
        expect(described_class.detect(file)).to eq(:rspec)
      end
    end

    it "detects minitest from require 'minitest'" do
      Dir.mktmpdir do |dir|
        file = File.join(dir, 'foo.rb')
        File.write(file, "require 'minitest'\n")
        expect(described_class.detect(file)).to eq(:minitest)
      end
    end

    it "detects minitest from require 'minitest/autorun'" do
      Dir.mktmpdir do |dir|
        file = File.join(dir, 'foo.rb')
        File.write(file, "require 'minitest/autorun'\n\nclass FooTest; end\n")
        expect(described_class.detect(file)).to eq(:minitest)
      end
    end

    it 'detects minitest from a double-quoted require "minitest/autorun"' do
      Dir.mktmpdir do |dir|
        file = File.join(dir, 'foo.rb')
        File.write(file, %(require "minitest/autorun"\n))
        expect(described_class.detect(file)).to eq(:minitest)
      end
    end

    it 'classifies latest.rb as minitest when its content requires minitest' do
      Dir.mktmpdir do |dir|
        file = File.join(dir, 'latest.rb')
        File.write(file, "require 'minitest/autorun'\n")
        expect(described_class.detect(file)).to eq(:minitest)
      end
    end

    it 'defaults to rspec for a missing file with an ambiguous name' do
      expect(described_class.detect('does_not_exist.rb')).to eq(:rspec)
    end
  end
end
