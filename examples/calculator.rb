class Calculator
  def add(a, b)
    a + b
  end

  def subtract(a, b)
    a - b
  end

  def multiply(a, b)
    a * b
  end

  def divide(a, b)
    return 0 if b == 0

    a / b
  end

  def is_positive?(number)
    number > 0
  end

  def is_even?(number)
    number % 2 == 0
  end

  def max(a, b)
    a > b ? a : b
  end

  def absolute(number)
    number < 0 ? -number : number
  end
end
