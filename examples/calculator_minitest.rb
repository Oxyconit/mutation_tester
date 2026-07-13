require 'minitest/autorun'
require_relative 'calculator'

class CalculatorTest < Minitest::Test
  def setup
    @calculator = Calculator.new
  end

  def test_add
    assert_equal 5, @calculator.add(2, 3)
    assert_equal(-5, @calculator.add(-2, -3))
  end

  def test_subtract
    assert_equal 2, @calculator.subtract(5, 3)
    assert_equal(-2, @calculator.subtract(3, 5))
  end

  def test_multiply
    assert_equal 12, @calculator.multiply(3, 4)
    assert_equal 0, @calculator.multiply(5, 0)
  end

  def test_divide
    assert_equal 5, @calculator.divide(10, 2)
    assert_equal 0, @calculator.divide(10, 0)
    assert_equal 3, @calculator.divide(7, 2)
  end

  def test_is_positive
    assert @calculator.is_positive?(5)
    refute(@calculator.is_positive?(-5))
    refute(@calculator.is_positive?(0))
  end

  def test_is_even
    assert @calculator.is_even?(4)
    refute(@calculator.is_even?(3))
    assert @calculator.is_even?(0)
  end

  def test_max
    assert_equal 5, @calculator.max(5, 3)
    assert_equal 5, @calculator.max(3, 5)
    assert_equal 5, @calculator.max(5, 5)
  end

  def test_absolute
    assert_equal 5, @calculator.absolute(5)
    assert_equal 5, @calculator.absolute(-5)
    assert_equal 0, @calculator.absolute(0)
  end
end
