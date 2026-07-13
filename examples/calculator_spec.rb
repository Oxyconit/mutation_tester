require_relative 'calculator'

RSpec.describe Calculator do
  subject(:calculator) { described_class.new }

  describe '#add' do
    it 'adds two numbers' do
      expect(calculator.add(2, 3)).to eq(5)
    end

    it 'adds negative numbers' do
      expect(calculator.add(-2, -3)).to eq(-5)
    end
  end

  describe '#subtract' do
    it 'subtracts two numbers' do
      expect(calculator.subtract(5, 3)).to eq(2)
    end

    it 'handles negative results' do
      expect(calculator.subtract(3, 5)).to eq(-2)
    end
  end

  describe '#multiply' do
    it 'multiplies two numbers' do
      expect(calculator.multiply(3, 4)).to eq(12)
    end

    it 'multiplies by zero' do
      expect(calculator.multiply(5, 0)).to eq(0)
    end
  end

  describe '#divide' do
    it 'divides two numbers' do
      expect(calculator.divide(10, 2)).to eq(5)
    end

    it 'returns 0 when dividing by zero' do
      expect(calculator.divide(10, 0)).to eq(0)
    end

    it 'handles integer division' do
      expect(calculator.divide(7, 2)).to eq(3)
    end
  end

  describe '#is_positive?' do
    it 'returns true for positive numbers' do
      expect(calculator.is_positive?(5)).to be true
    end

    it 'returns false for negative numbers' do
      expect(calculator.is_positive?(-5)).to be false
    end

    it 'returns false for zero' do
      expect(calculator.is_positive?(0)).to be false
    end
  end

  describe '#is_even?' do
    it 'returns true for even numbers' do
      expect(calculator.is_even?(4)).to be true
    end

    it 'returns false for odd numbers' do
      expect(calculator.is_even?(3)).to be false
    end

    it 'returns true for zero' do
      expect(calculator.is_even?(0)).to be true
    end
  end

  describe '#max' do
    it 'returns the larger number when first is larger' do
      expect(calculator.max(5, 3)).to eq(5)
    end

    it 'returns the larger number when second is larger' do
      expect(calculator.max(3, 5)).to eq(5)
    end

    it 'returns the number when both are equal' do
      expect(calculator.max(5, 5)).to eq(5)
    end
  end

  describe '#absolute' do
    it 'returns positive number unchanged' do
      expect(calculator.absolute(5)).to eq(5)
    end

    it 'returns absolute value of negative number' do
      expect(calculator.absolute(-5)).to eq(5)
    end

    it 'returns zero for zero' do
      expect(calculator.absolute(0)).to eq(0)
    end
  end
end
