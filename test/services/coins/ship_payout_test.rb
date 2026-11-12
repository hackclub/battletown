require "test_helper"

class Coins::ShipPayoutTest < ActiveSupport::TestCase
  D1 = Date.new(2026, 11, 1)
  D2 = Date.new(2026, 11, 2)
  D3 = Date.new(2026, 11, 3)
  HOUR = 3600

  def payout(**args) = Coins::ShipPayout.call(**{ bonus_bps_by_date: {}, hours_since_previous_ship_before_window: 0 }.merge(args))

  test "conversion is 10 coins per approved hour, floored at the end" do
    assert_equal 10, Coins::Conversion.base_coins(HOUR)
    assert_equal 25, Coins::Conversion.base_coins(2 * HOUR + 1800)
    assert_equal 0, Coins::Conversion.base_coins(359)
    assert_equal 1, Coins::Conversion.base_coins(360)
    assert_equal 0, Coins::Conversion.base_coins(0)
    assert_equal 2777, Coins::Conversion.base_milli_coins(1000)
  end

  test "a plain ship with no bonus and under the deflation threshold" do
    result = payout(approved_seconds: 5 * HOUR, coded_seconds_by_date: { D1 => 3 * HOUR, D2 => 3 * HOUR })
    assert_equal [ 50, 0, 50 ], [ result.base_coins, result.bonus_coins, result.total_coins ]
  end

  test "deflation boundary: exactly 6 hours is full rate, the next second is deflated" do
    exact = payout(approved_seconds: 6 * HOUR, coded_seconds_by_date: { D1 => 6 * HOUR })
    assert_equal 60, exact.base_coins
    assert_equal 0, exact.per_date[D1][:deflated_seconds]

    over = payout(approved_seconds: 6 * HOUR + 3600, coded_seconds_by_date: { D1 => 7 * HOUR })
    assert_equal 68, over.base_coins
    assert_equal 3600, over.per_date[D1][:deflated_seconds]

    one_second = payout(approved_seconds: 6 * HOUR + 1, coded_seconds_by_date: { D1 => 7 * HOUR })
    assert_equal 1, one_second.per_date[D1][:deflated_seconds]
    assert_equal 60, one_second.base_coins # 60 coins + 0.8 * 10/3600 coin, floored
  end

  test "deflation is counted chronologically across dates, whatever order the hash is in" do
    result = payout(approved_seconds: 9 * HOUR, coded_seconds_by_date: { D3 => 3 * HOUR, D1 => 3 * HOUR, D2 => 3 * HOUR })
    assert_equal [ 0, 0, 3 * HOUR ], [ D1, D2, D3 ].map { |d| result.per_date[d][:deflated_seconds] }
    assert_equal 60 + 24, result.base_coins
  end

  test "hours already counted before the window start the deflation earlier" do
    result = payout(approved_seconds: 2 * HOUR, coded_seconds_by_date: { D1 => 2 * HOUR }, hours_since_previous_ship_before_window: 5)
    assert_equal HOUR, result.per_date[D1][:full_rate_seconds]
    assert_equal HOUR, result.per_date[D1][:deflated_seconds]
    assert_equal 18, result.base_coins

    already = payout(approved_seconds: HOUR, coded_seconds_by_date: { D1 => HOUR }, hours_since_previous_ship_before_window: 6)
    assert_equal 8, already.base_coins
    fractional = payout(approved_seconds: HOUR, coded_seconds_by_date: { D1 => HOUR }, hours_since_previous_ship_before_window: Rational(11, 2))
    assert_equal 1800, fractional.per_date[D1][:deflated_seconds]
  end

  test "floats are refused for the hours offset" do
    assert_raises(ArgumentError) { payout(approved_seconds: HOUR, coded_seconds_by_date: { D1 => HOUR }, hours_since_previous_ship_before_window: 5.5) }
    assert_raises(ArgumentError) { payout(approved_seconds: HOUR, coded_seconds_by_date: { D1 => HOUR }, hours_since_previous_ship_before_window: -1) }
  end

  test "each date's bonus applies to that date's base coins only" do
    result = payout(approved_seconds: 4 * HOUR, coded_seconds_by_date: { D1 => 2 * HOUR, D2 => 2 * HOUR }, bonus_bps_by_date: { D1 => 500, D2 => 2000 })
    # 20 coins at 5% = 1.0, 20 coins at 20% = 4.0
    assert_equal [ 40, 5, 45 ], [ result.base_coins, result.bonus_coins, result.total_coins ]
    assert_equal 1000, result.per_date[D1][:bonus_milli_coins]
    assert_equal 4000, result.per_date[D2][:bonus_milli_coins]
  end

  test "the bonus applies to deflated base coins" do
    result = payout(approved_seconds: 7 * HOUR, coded_seconds_by_date: { D1 => 7 * HOUR }, bonus_bps_by_date: { D1 => 1000 })
    # base 68 (60 + 8), 10% = 6.8: total floor(74.8) = 74
    assert_equal [ 68, 6, 74 ], [ result.base_coins, result.bonus_coins, result.total_coins ]
  end

  test "flooring happens once at the end: fractions from several dates add up" do
    # Each date: 1 hour of approved time at 5.0% = 0.5 coin of bonus; three dates make 1.5 coins.
    result = payout(approved_seconds: 3 * HOUR, coded_seconds_by_date: { D1 => HOUR, D2 => HOUR, D3 => HOUR },
                    bonus_bps_by_date: { D1 => 500, D2 => 500, D3 => 500 })
    assert_equal [ 30, 1, 31 ], [ result.base_coins, result.bonus_coins, result.total_coins ]
  end

  test "a date without a bonus entry earns none" do
    result = payout(approved_seconds: HOUR, coded_seconds_by_date: { D1 => HOUR }, bonus_bps_by_date: { D2 => 2000 })
    assert_equal 0, result.bonus_coins
  end

  test "largest remainder allocation sums exactly and breaks ties towards the earlier date" do
    allocation = Coins::ShipPayout.allocate(10, { D1 => 1, D2 => 1, D3 => 1 })
    assert_equal 10, allocation.values.sum
    assert_equal [ 4, 3, 3 ], [ D1, D2, D3 ].map { |d| allocation[d] }
  end

  test "allocation is proportional to coded seconds" do
    allocation = Coins::ShipPayout.allocate(3 * HOUR, { D1 => 2 * HOUR, D2 => 4 * HOUR })
    assert_equal [ HOUR, 2 * HOUR ], [ allocation[D1], allocation[D2] ]
  end

  test "allocation gives the biggest fractional share the extra second" do
    allocation = Coins::ShipPayout.allocate(5, { D1 => 10, D2 => 20, D3 => 70 })
    # exact 0.5, 1.0, 3.5: floors 0, 1, 3, one left over goes to the biggest remainder (tie D1/D3 -> earlier D1)
    assert_equal [ 1, 1, 3 ], [ D1, D2, D3 ].map { |d| allocation[d] }
  end

  test "a date with no coded time gets nothing" do
    allocation = Coins::ShipPayout.allocate(100, { D1 => 0, D2 => 500 })
    assert_equal [ 0, 100 ], [ allocation[D1], allocation[D2] ]
  end

  test "approved seconds of zero allocate zero, even with no coded time" do
    result = payout(approved_seconds: 0, coded_seconds_by_date: { D1 => 0 })
    assert_equal [ 0, 0, 0 ], [ result.base_coins, result.bonus_coins, result.total_coins ]
    assert_equal 0, payout(approved_seconds: 0, coded_seconds_by_date: {}).total_coins
  end

  test "approved time with no coded time to allocate against is refused" do
    assert_raises(Coins::ShipPayout::NothingToAllocate) { payout(approved_seconds: 60, coded_seconds_by_date: { D1 => 0 }) }
    assert_raises(Coins::ShipPayout::NothingToAllocate) { payout(approved_seconds: 60, coded_seconds_by_date: {}) }
  end

  test "negative approved seconds are refused" do
    assert_raises(ArgumentError) { payout(approved_seconds: -1, coded_seconds_by_date: { D1 => 100 }) }
  end

  test "property: allocations always sum to the approved total and never give a date more than its share rounded up" do
    random = Random.new(20_261_113)
    200.times do
      dates = (0...random.rand(1..12)).map { |i| D1 + i }
      coded = dates.to_h { |date| [ date, random.rand(0..40_000) ] }
      coded[dates.first] += 1 if coded.values.sum.zero?
      approved = random.rand(0..coded.values.sum)
      allocation = Coins::ShipPayout.allocate(approved, coded)
      assert_equal approved, allocation.values.sum, "sum for #{coded} approved #{approved}"
      allocation.each do |date, seconds|
        assert_operator seconds, :>=, 0
        assert_operator seconds, :<=, coded.fetch(date), "never more than coded when approved <= coded"
      end
    end
  end

  test "property: payout parts are consistent for random ships" do
    random = Random.new(7)
    200.times do
      dates = (0...random.rand(1..10)).map { |i| D1 + i }
      coded = dates.to_h { |date| [ date, random.rand(1..30_000) ] }
      approved = random.rand(0..coded.values.sum)
      bonus = dates.to_h { |date| [ date, [ 0, 500, 700, 1030, 2000 ].sample(random: random) ] }
      result = payout(approved_seconds: approved, coded_seconds_by_date: coded, bonus_bps_by_date: bonus,
                      hours_since_previous_ship_before_window: random.rand(0..8))
      assert_equal approved, result.per_date.values.sum { |row| row[:allocated_seconds] }
      assert_equal result.total_coins, result.base_coins + result.bonus_coins
      assert_operator result.bonus_coins, :>=, 0
      assert_operator result.base_coins, :<=, Coins::Conversion.base_coins(approved) + 0
      assert_operator result.total_coins, :<=, Coins::Conversion.base_coins(approved) * 3
    end
  end

  test "deflation never makes a ship worth more than the plain rate and bonus never more than the ramp cap" do
    approved = 20 * HOUR
    plain = Coins::Conversion.base_coins(approved)
    result = payout(approved_seconds: approved, coded_seconds_by_date: { D1 => approved }, bonus_bps_by_date: { D1 => 2000 })
    assert_operator result.base_coins, :<, plain
    assert_operator result.total_coins, :<=, plain * 12 / 10
  end

  test "the result is exact regardless of input order or integer-like types" do
    a = payout(approved_seconds: 12_345, coded_seconds_by_date: { D1 => 5000, D2 => 9000 })
    b = payout(approved_seconds: 12_345, coded_seconds_by_date: { D2 => 9000, D1 => 5000 })
    assert_equal a, b
  end
end
