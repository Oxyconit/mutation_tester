require 'spec_helper'
require 'tmpdir'
require 'rbconfig'

RSpec.describe 'the minitest fail-fast preload' do
  def write_test_file(dir, outcome)
    path = File.join(dir, 'marker_test.rb')
    File.write(path, <<~RUBY)
      require 'minitest/autorun'

      class MarkerTest < Minitest::Test
        %w[a b c].each do |name|
          define_method("test_\#{name}") do
            File.write(File.join(#{dir.inspect}, "ran-\#{name}.txt"), 'x')
            #{outcome}
          end
        end
      end
    RUBY
    path
  end

  def run_test_file(path, dir, with_shim:)
    argv = [RbConfig.ruby]
    argv += ['-r', MutationTester::TestCommand::MINITEST_FAIL_FAST_PATH] if with_shim
    argv << path
    system(*argv, chdir: dir, out: File::NULL, err: File::NULL)
  end

  def markers(dir)
    Dir.glob(File.join(dir, 'ran-*.txt')).size
  end

  it 'stops a failing file after the first failing test instead of running the rest' do
    Dir.mktmpdir do |dir|
      path = write_test_file(dir, "flunk 'boom'")

      expect(run_test_file(path, dir, with_shim: true)).to be(false)
      expect(markers(dir)).to eq(1)
    end
  end

  it 'runs every test of the same failing file without the preload' do
    Dir.mktmpdir do |dir|
      path = write_test_file(dir, "flunk 'boom'")

      expect(run_test_file(path, dir, with_shim: false)).to be(false)
      expect(markers(dir)).to eq(3)
    end
  end

  it 'leaves a passing file untouched: every test runs and the file still passes' do
    Dir.mktmpdir do |dir|
      path = write_test_file(dir, 'assert true')

      expect(run_test_file(path, dir, with_shim: true)).to be(true)
      expect(markers(dir)).to eq(3)
    end
  end
end
