require 'minitest/autorun'
require_relative 'adder'

class AdderTest < Minitest::Test
  def test_add
    assert_equal 8, Adder.new.add(6, 2)
  end
end
