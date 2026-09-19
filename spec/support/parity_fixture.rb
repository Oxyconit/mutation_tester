module ParityFixture
  SOURCE = <<~RUBY
    module Basket
      class Pricer
        FREE_DELIVERY_THRESHOLD = 200
        PRICES = { pencil: 1, book: 199, lamp: 260 }
        Receipt = Struct.new(:total, :label)

        def initialize(vip: false)
          @vip = vip
          @item_ids = []
        end

        def add(item_id)
          @item_ids.push(item_id)
          self
        end

        def total
          @item_ids.uniq.sum { |id| PRICES.fetch(id) }
        end

        def free_delivery?
          @vip || total >= FREE_DELIVERY_THRESHOLD
        end

        def premium_item?(item_id)
          item_id == :lamp
        end

        def receipt_label
          "total: \#{total} PLN"
        end

        def receipt
          Receipt.new(total, receipt_label)
        end

        def discounted_total(rate)
          (total * rate).round(2)
        end

        def charge(amount)
          raise ArgumentError, 'amount must be positive' unless amount.positive?

          amount
        end

        def bulk_quantity?(quantity)
          (10..99).cover?(quantity)
        end

        def summary
          { vip: @vip }.merge(total: total, count: @item_ids.size)
        end
      end
    end
  RUBY

  WEAK_SPEC = <<~RUBY
    require_relative '../lib/pricer'

    RSpec.describe Basket::Pricer do
      it 'ships expensive baskets for free' do
        pricer = Basket::Pricer.new(vip: false)
        pricer.add(:lamp)
        expect(pricer.free_delivery?).to be(true)
      end

      it 'charges delivery for cheap baskets' do
        pricer = Basket::Pricer.new(vip: false)
        pricer.add(:pencil)
        expect(pricer.free_delivery?).to be(false)
      end

      it 'sums the basket total' do
        pricer = Basket::Pricer.new(vip: false)
        pricer.add(:pencil)
        pricer.add(:book)
        expect(pricer.total).to eq(200)
      end

      it 'labels the receipt' do
        pricer = Basket::Pricer.new(vip: false)
        pricer.add(:pencil)
        expect(pricer.receipt_label).to be_a(String)
      end

      it 'discounts the total' do
        pricer = Basket::Pricer.new(vip: false)
        pricer.add(:lamp)
        expect(pricer.discounted_total(0.2)).to eq(52.0)
      end

      it 'returns the charged amount' do
        pricer = Basket::Pricer.new(vip: false)
        expect(pricer.charge(50)).to eq(50)
      end

      it 'rejects a non-positive charge' do
        pricer = Basket::Pricer.new(vip: false)
        expect { pricer.charge(-1) }.to raise_error(ArgumentError)
      end
    end
  RUBY

  COMPLETE_SPEC = <<~RUBY
    require_relative '../lib/pricer'

    RSpec.describe Basket::Pricer do
      def pricer(vip: false)
        Basket::Pricer.new(vip: vip)
      end

      it 'prices a pencil' do
        subject = pricer
        subject.add(:pencil)
        expect(subject.total).to eq(1)
      end

      it 'prices a book' do
        subject = pricer
        subject.add(:book)
        expect(subject.total).to eq(199)
      end

      it 'prices a lamp' do
        subject = pricer
        subject.add(:lamp)
        expect(subject.total).to eq(260)
      end

      it 'counts a duplicate item only once' do
        subject = pricer
        subject.add(:pencil)
        subject.add(:pencil)
        subject.add(:book)
        expect(subject.total).to eq(200)
      end

      it 'returns itself from add for chaining' do
        subject = pricer
        expect(subject.add(:pencil)).to be(subject)
      end

      it 'gives free delivery exactly at the threshold' do
        subject = pricer
        subject.add(:book)
        subject.add(:pencil)
        expect(subject.free_delivery?).to be(true)
      end

      it 'charges delivery one unit below the threshold' do
        subject = pricer
        subject.add(:book)
        expect(subject.free_delivery?).to be(false)
      end

      it 'gives free delivery above the threshold' do
        subject = pricer
        subject.add(:lamp)
        expect(subject.free_delivery?).to be(true)
      end

      it 'charges delivery for a cheap basket' do
        subject = pricer
        subject.add(:pencil)
        expect(subject.free_delivery?).to be(false)
      end

      it 'gives a vip free delivery on a cheap basket' do
        subject = pricer(vip: true)
        subject.add(:pencil)
        expect(subject.free_delivery?).to be(true)
      end

      it 'charges delivery for a cheap basket by default' do
        subject = Basket::Pricer.new
        subject.add(:pencil)
        expect(subject.free_delivery?).to be(false)
      end

      it 'flags the lamp as a premium item' do
        expect(pricer.premium_item?(:lamp)).to be(true)
      end

      it 'does not flag a pencil as a premium item' do
        expect(pricer.premium_item?(:pencil)).to be(false)
      end

      it 'formats the receipt label' do
        subject = pricer
        subject.add(:pencil)
        expect(subject.receipt_label).to eq('total: 1 PLN')
      end

      it 'issues a receipt carrying the total and the label' do
        subject = pricer
        subject.add(:pencil)
        receipt = subject.receipt
        expect(receipt.total).to eq(1)
        expect(receipt.label).to eq('total: 1 PLN')
      end

      it 'rounds the discounted total to exactly two decimals' do
        subject = pricer
        subject.add(:pencil)
        expect(subject.discounted_total(0.333)).to eq(0.33)
      end

      it 'returns the charged amount' do
        expect(pricer.charge(50)).to eq(50)
      end

      it 'rejects a non-positive charge with an exact message' do
        expect { pricer.charge(-1) }.to raise_error(ArgumentError, 'amount must be positive')
      end

      it 'treats the lowest and the highest bulk quantity as bulk' do
        expect(pricer.bulk_quantity?(10)).to be(true)
        expect(pricer.bulk_quantity?(99)).to be(true)
      end

      it 'does not treat a quantity just outside the bulk bounds as bulk' do
        expect(pricer.bulk_quantity?(9)).to be(false)
        expect(pricer.bulk_quantity?(100)).to be(false)
      end

      it 'summarizes the vip flag, the total and the item count' do
        subject = pricer(vip: true)
        subject.add(:pencil)
        expect(subject.summary).to eq(vip: true, total: 1, count: 1)
      end
    end
  RUBY

  LOAD_CRASH_SOURCE = <<~RUBY
    class Till
      Receipt = Struct.new(:amount, :label)

      def initialize(amount)
        @amount = amount
      end

      def receipt
        Receipt.new(@amount, 'due')
      end

      def paid?(payment)
        payment >= @amount
      end
    end
  RUBY

  LOAD_CRASH_SPEC = <<~RUBY
    require_relative '../lib/till'

    RSpec.describe Till do
      it 'issues a receipt with the amount and the label' do
        receipt = Till.new(5).receipt
        expect(receipt.amount).to eq(5)
        expect(receipt.label).to eq('due')
      end

      it 'confirms an exact payment' do
        expect(Till.new(5).paid?(5)).to be(true)
      end
    end
  RUBY

  LOAD_CRASH_STRUCT_LINE = LOAD_CRASH_SOURCE.lines.index { |line| line.include?('Struct.new') } + 1

  def self.line_of(fragment)
    index = SOURCE.lines.index { |line| line.include?(fragment) }
    raise ArgumentError, "fixture source does not contain #{fragment.inspect}" unless index

    index + 1
  end

  THRESHOLD_CONSTANT_LINE = line_of('FREE_DELIVERY_THRESHOLD = 200')
  THRESHOLD_COMPARISON_LINE = line_of('total >= FREE_DELIVERY_THRESHOLD')

  GAP_CLASSES = {
    'G1' => {
      gap: 'an untested comparison boundary at the free delivery threshold',
      family: :comparison,
      line: THRESHOLD_COMPARISON_LINE,
      matching: { original: '>=', mutated: '>' }
    },
    'G2' => {
      gap: 'an untested class constant boundary',
      family: :number,
      line: THRESHOLD_CONSTANT_LINE,
      matching: { original: '200', mutated: '199' }
    },
    'G3' => {
      gap: 'an untested vip flag path in a logical or',
      family: :logical,
      line: line_of('@vip || total'),
      matching: { description: 'Remove operand @vip from ||' }
    },
    'G4' => {
      gap: 'an unverified uniq transformation in the total',
      family: :call_removal,
      line: line_of('.uniq.sum'),
      matching: { description: 'Remove uniq call' }
    },
    'G5' => {
      gap: 'an unasserted fluent self return from add',
      family: :nil_injection,
      line: line_of('    self'),
      matching: { original: 'self' }
    },
    'G6' => {
      gap: 'an unasserted receipt label format',
      family: :string,
      line: line_of('PLN"'),
      matching: {}
    },
    'G7' => {
      gap: 'an unexercised vip argument default',
      family: :argument,
      line: line_of('vip: false'),
      matching: { description: 'Remove default value of vip' }
    },
    'G8' => {
      gap: 'an unforced two-decimal rounding precision',
      family: :number,
      line: line_of('.round(2)'),
      matching: { original: '2' }
    },
    'G9' => {
      gap: 'an unasserted exception message',
      family: :string,
      line: line_of('amount must be positive'),
      matching: { original: "'amount must be positive'" }
    }
  }.freeze
end
