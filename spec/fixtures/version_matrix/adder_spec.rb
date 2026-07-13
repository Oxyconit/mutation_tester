require_relative 'adder'

RSpec.describe Adder do
  it 'adds two numbers' do
    expect(described_class.new.add(6, 2)).to eq(8)
  end
end
