require "test_helper"

# The pure crew bonus maths: no database. 10 coins per approved hour (config/game.yml coins.per_approved_hour), 5% bonus.
class Teams::BonusTest < ActiveSupport::TestCase
  HOUR = 3600
  D = ->(day) { Date.new(2026, 11, day) }
  UTC = ActiveSupport::TimeZone["UTC"]
  LONG_AGO = Time.utc(2026, 1, 1)
  THRESHOLD = 900
  BPS = 500

  # member(D[2] => 900) reads as keywords to Ruby, so date keys that arrive as keywords are merged into the seconds.
  def member(seconds = {}, joined_at: LONG_AGO, zone: UTC, **by_date)
    Teams::Bonus::Member.new(joined_at: joined_at, zone: zone, seconds_by_date: seconds.merge(by_date))
  end

  def bonus(by_date, mates, earner: member(by_date), approved: by_date.values.sum, bps: BPS, eligible: nil)
    Teams::Bonus.call(approved_seconds: approved, coded_seconds_by_date: by_date, earner: earner, crewmates: mates, threshold: THRESHOLD, bps: bps,
                      eligible_dates: eligible)
  end

  test "a day a crewmate also coded earns the bonus on that day's coins" do
    result = bonus({ D[2] => 4 * HOUR }, [ member(D[2] => 900) ])
    assert_equal [ D[2] ], result.matched_dates
    assert_equal 2, result.bonus_coins # 40 coins x 5% = 2
  end

  test "a day nobody else coded earns nothing" do
    result = bonus({ D[2] => 4 * HOUR }, [ member(D[3] => 4 * HOUR) ])
    assert_empty result.matched_dates
    assert_equal 0, result.bonus_coins
  end

  test "only the matched days of a ship are paid, in proportion to their own coins" do
    result = bonus({ D[2] => 2 * HOUR, D[3] => 4 * HOUR, D[4] => 4 * HOUR }, [ member(D[3] => 3600) ])
    assert_equal [ D[3] ], result.matched_dates
    assert_equal 2, result.bonus_coins # 40 coins on the 3rd x 5%
  end

  test "the crewmate needs at least the 15 minute threshold: 899 seconds is not enough, 900 is" do
    assert_equal 0, bonus({ D[2] => 4 * HOUR }, [ member(D[2] => 899) ]).bonus_coins
    assert_equal 2, bonus({ D[2] => 4 * HOUR }, [ member(D[2] => 900) ]).bonus_coins
  end

  test "one matching crewmate is enough, however many others did not code" do
    mates = [ member({}), member(D[2] => 100), member(D[2] => 5 * HOUR), member(D[5] => HOUR) ]
    assert_equal [ D[2] ], bonus({ D[2] => 4 * HOUR }, mates).matched_dates
  end

  test "a second matching crewmate adds nothing: the bonus is per day, not per crewmate" do
    one = bonus({ D[2] => 4 * HOUR }, [ member(D[2] => HOUR) ])
    four = bonus({ D[2] => 4 * HOUR }, Array.new(4) { member(D[2] => HOUR) })
    assert_equal one.bonus_coins, four.bonus_coins
  end

  test "a crew of one, or nobody else, earns nothing" do
    assert_equal 0, bonus({ D[2] => 4 * HOUR }, []).bonus_coins
  end

  test "the bonus is floored once, never rounded up" do
    assert_equal 3, bonus({ D[2] => 7 * HOUR }, [ member(D[2] => HOUR) ]).bonus_coins # 6 h at 10 + 1 h at 8 = 68; 3.4
    assert_equal 0, bonus({ D[2] => HOUR }, [ member(D[2] => HOUR) ]).bonus_coins # 10 coins x 5% = 0.5
    assert_equal 1, bonus({ D[2] => 2 * HOUR }, [ member(D[2] => HOUR) ]).bonus_coins # exactly 1
  end

  test "floors the sum of the matched days, so two half coins make one" do
    result = bonus({ D[2] => HOUR, D[3] => HOUR }, [ member(D[2] => HOUR, D[3] => HOUR) ])
    assert_equal 1, result.bonus_coins
  end

  test "deflated hours past the threshold carry the deflated base" do
    # 8 hours on one day: 6 at 10 coins + 2 at 8 coins = 76 coins; 5% = 3.8
    assert_equal 3, bonus({ D[2] => 8 * HOUR }, [ member(D[2] => HOUR) ]).bonus_coins
  end

  test "a lowered approval (fewer approved than coded seconds) lowers the base the bonus rides on" do
    result = bonus({ D[2] => 4 * HOUR }, [ member(D[2] => HOUR) ], approved: 2 * HOUR)
    assert_equal 1, result.bonus_coins # 20 coins x 5%
  end

  test "the percentage comes from basis points" do
    assert_equal 4, bonus({ D[2] => 4 * HOUR }, [ member(D[2] => HOUR) ], bps: 1000).bonus_coins
    assert_equal 0, bonus({ D[2] => 4 * HOUR }, [ member(D[2] => HOUR) ], bps: 0).bonus_coins
  end

  test "dates outside the eligible list are never matched" do
    result = bonus({ D[2] => 4 * HOUR, D[3] => 4 * HOUR }, [ member(D[2] => HOUR, D[3] => HOUR) ], eligible: [ D[2] ])
    assert_equal [ D[2] ], result.matched_dates
  end

  # --- when each person joined ---

  test "a crewmate who joined during the day is in from the next day, not that day" do
    mate = member({ D[5] => HOUR, D[6] => HOUR }, joined_at: Time.utc(2026, 11, 5, 15))
    assert_equal [ D[6] ], bonus({ D[5] => HOUR, D[6] => HOUR }, [ mate ]).matched_dates
  end

  test "joining exactly at midnight counts for that whole date, one second later does not" do
    by_date = { D[5] => HOUR }
    assert_equal [ D[5] ], bonus(by_date, [ member(by_date, joined_at: Time.utc(2026, 11, 5, 0, 0, 0)) ]).matched_dates
    assert_empty bonus(by_date, [ member(by_date, joined_at: Time.utc(2026, 11, 5, 0, 0, 1)) ]).matched_dates
  end

  test "the earner must also have been in the crew for the whole date" do
    by_date = { D[5] => HOUR, D[6] => HOUR }
    earner = member(by_date, joined_at: Time.utc(2026, 11, 5, 18))
    assert_equal [ D[6] ], bonus(by_date, [ member(by_date) ], earner: earner).matched_dates
  end

  # --- time zones ---

  test "each person's join is measured against the start of the date in their own zone" do
    auckland = ActiveSupport::TimeZone["Auckland"] # UTC+13 in November: the 6th begins at 11:00 UTC on the 5th
    by_date = { D[6] => HOUR }
    on_time = member(by_date, joined_at: Time.utc(2026, 11, 5, 11), zone: auckland)
    late = member(by_date, joined_at: Time.utc(2026, 11, 5, 11, 0, 1), zone: auckland)
    assert_equal [ D[6] ], bonus(by_date, [ on_time ]).matched_dates
    assert_empty bonus(by_date, [ late ]).matched_dates
  end

  test "the start of a date follows daylight saving: the day the clocks change is still one date" do
    new_york = ActiveSupport::TimeZone["America/New_York"]
    spring = Date.new(2026, 3, 8) # 23 hours long; midnight is 05:00 UTC, the day before is EST
    fall = Date.new(2026, 11, 1)  # 25 hours long; midnight is 04:00 UTC (EDT)
    assert_equal [ spring ], bonus({ spring => HOUR }, [ member({ spring => HOUR }, joined_at: Time.utc(2026, 3, 8, 5), zone: new_york) ]).matched_dates
    assert_empty bonus({ spring => HOUR }, [ member({ spring => HOUR }, joined_at: Time.utc(2026, 3, 8, 5, 0, 1), zone: new_york) ]).matched_dates
    assert_equal [ fall ], bonus({ fall => HOUR }, [ member({ fall => HOUR }, joined_at: Time.utc(2026, 11, 1, 4), zone: new_york) ]).matched_dates
    assert_empty bonus({ fall => HOUR }, [ member({ fall => HOUR }, joined_at: Time.utc(2026, 11, 1, 4, 0, 1), zone: new_york) ]).matched_dates
  end

  test "a crewmate's own local date is the one that matches" do
    # They coded on their local 10 Nov; the earner's ship day is also labelled 10 Nov: those match, whatever the clock offset.
    tokyo = ActiveSupport::TimeZone["Tokyo"]
    mate = member({ D[10] => HOUR }, zone: tokyo)
    assert_equal [ D[10] ], bonus({ D[10] => HOUR }, [ mate ]).matched_dates
  end

  # --- the formula, against ship_payout ---

  test "with every date matched the bonus equals floor of the whole base times the bonus" do
    by_date = { D[2] => 3 * HOUR, D[3] => 5 * HOUR }
    payout = Coins::ShipPayout.call(approved_seconds: 8 * HOUR, coded_seconds_by_date: by_date)
    result = bonus(by_date, [ member(by_date) ], approved: 8 * HOUR)
    assert_equal (payout.base_coins * BPS) / 10_000, result.bonus_coins # 76 coins x 5% = 3.8 -> 3
  end
end
