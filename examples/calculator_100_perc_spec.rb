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

    it 'returns zero when multiplying by zero' do
      expect(calculator.multiply(5, 0)).to eq(0)
    end
  end

  describe '#divide' do
    context 'when divisor is zero' do
      it 'returns 0' do
        expect(calculator.divide(10, 0)).to eq(0)
      end
    end

    context 'when divisor is non-zero' do
      it 'divides two numbers' do
        expect(calculator.divide(10, 2)).to eq(5)
      end

      it 'performs integer division for integers' do
        expect(calculator.divide(7, 2)).to eq(3)
      end
    end
  end

  describe '#is_positive?' do
    it 'returns true for positive integers' do
      expect(calculator.is_positive?(5)).to be true
      expect(calculator.is_positive?(1)).to be true
    end

    it 'returns true for fractional positives' do
      expect(calculator.is_positive?(0.5)).to be true
    end

    it 'returns false for zero and negatives' do
      expect(calculator.is_positive?(0)).to be false
      expect(calculator.is_positive?(-0.1)).to be false
      expect(calculator.is_positive?(-1)).to be false
    end
  end

  describe '#is_even?' do
    it 'returns true for even numbers and zero' do
      expect(calculator.is_even?(4)).to be true
      expect(calculator.is_even?(0)).to be true
    end

    it 'returns false for odd numbers' do
      expect(calculator.is_even?(3)).to be false
    end
  end

  describe '#max' do
    it 'returns the larger number' do
      expect(calculator.max(5, 3)).to eq(5)
      expect(calculator.max(3, 5)).to eq(5)
    end

    it 'returns the second object when values are equal' do
      a = String.new('same')
      b = String.new('same')
      expect(calculator.max(a, b)).to equal(b)
    end
  end

  describe '#absolute' do
    it 'returns positive number unchanged' do
      expect(calculator.absolute(5)).to eq(5)
    end

    it 'returns absolute value for negative numbers' do
      expect(calculator.absolute(-5)).to eq(5)
      expect(calculator.absolute(-1)).to eq(1)
    end

    it 'distinguishes negative zero and positive zero for floats' do
      neg_zero = calculator.absolute(-0.0)
      pos_zero = calculator.absolute(0.0)

      expect(1.0 / neg_zero).to eq(-Float::INFINITY)
      expect(1.0 / pos_zero).to eq(Float::INFINITY)
    end

    it 'returns zero for integer zero' do
      expect(calculator.absolute(0)).to eq(0)
    end

    it 'handles fractional positives' do
      expect(calculator.absolute(0.5)).to eq(0.5)
    end
  end
end
