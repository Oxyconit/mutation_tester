module BenchPricerFixture
  SOURCE = <<~'RUBY'
    module Basket
      class Pricer
        BULK_THRESHOLD = 10
        BULK_DISCOUNT = 0.1
        FREE_SHIPPING_ABOVE = 200
        SHIPPING_FEE = 15
        CURRENCY = 'PLN'

        Result = Struct.new(:subtotal, :discount, :shipping, :total, :label)

        def initialize(vip: false)
          @vip = vip
        end

        def price(unit_price, quantity = 1)
          raise ArgumentError, 'quantity must be positive' if quantity < 1

          subtotal = unit_price * quantity
          discount = bulk_discount(subtotal, quantity)
          shipping = shipping_fee(subtotal - discount)
          total = subtotal - discount + shipping
          Result.new(subtotal, discount, shipping, total, format_label(total))
        end

        def bulk_discount(subtotal, quantity)
          return 0 unless quantity >= BULK_THRESHOLD

          (subtotal * BULK_DISCOUNT).round(2)
        end

        def shipping_fee(amount)
          return 0 if @vip || amount >= FREE_SHIPPING_ABOVE

          SHIPPING_FEE
        end

        def format_label(total)
          "#{format('%.2f', total)} #{CURRENCY}"
        end

        def total_of(item_ids, catalog)
          item_ids.uniq.sum { |id| catalog.fetch(id) }
        end

        def register_sale!(ledger, amount)
          ledger << amount
          self
        end
      end
    end
  RUBY

  WEAK_SPEC = <<~'RUBY'
    # Spec z CELOWO zostawionymi lukami (ground truth do porownania narzedzi):
    # G1: prog rabatu hurtowego (quantity == 10) nietestowany na granicy
    # G2: prog darmowej dostawy nietestowany tuz ponizej granicy (199)
    # G3: sciezka VIP nigdy nie testowana
    # G4: total_of nigdy nie dostaje duplikatow (uniq nieweryfikowane)
    # G5: wartosc zwracana register_sale! nigdy nie asertowana
    # G6: format etykiety (label / 'PLN') nigdy nie asertowany
    # G7: domyslna wartosc quantity = 1 nigdy nie uzyta w testach
    require_relative '../spec_helper'

    RSpec.describe Basket::Pricer do
      subject(:pricer) { described_class.new }

      describe '#price' do
        it 'prices a single cheap item with flat shipping' do
          result = pricer.price(50, 1)
          expect(result.subtotal).to eq(50)
          expect(result.discount).to eq(0)
          expect(result.shipping).to eq(15)
          expect(result.total).to eq(65)
        end

        it 'applies the bulk discount for large quantities' do
          result = pricer.price(10, 20)
          expect(result.subtotal).to eq(200)
          expect(result.discount).to eq(20.0)
          expect(result.shipping).to eq(15)
          expect(result.total).to eq(195.0)
        end

        it 'gives free shipping at exactly the threshold' do
          result = pricer.price(200, 1)
          expect(result.shipping).to eq(0)
          expect(result.total).to eq(200)
        end

        it 'gives free shipping above the threshold' do
          result = pricer.price(300, 1)
          expect(result.shipping).to eq(0)
          expect(result.total).to eq(300)
        end

        it 'rejects a non-positive quantity' do
          expect { pricer.price(10, 0) }.to raise_error(ArgumentError)
        end
      end

      describe '#total_of' do
        it 'sums catalog prices for the given ids' do
          expect(pricer.total_of(%i[a b], { a: 1, b: 2 })).to eq(3)
        end
      end

      describe '#register_sale!' do
        it 'appends the amount to the ledger' do
          ledger = []
          pricer.register_sale!(ledger, 42)
          expect(ledger).to eq([42])
        end
      end
    end
  RUBY

  SPEC_HELPER = <<~'RUBY'
    require_relative '../lib/basket/pricer'
  RUBY
end
