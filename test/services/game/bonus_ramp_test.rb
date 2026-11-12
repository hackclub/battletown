require "test_helper"

class Game::BonusRampTest < ActiveSupport::TestCase
  # The table is one decimal per day. Days 3 to 13 are the line from day 2 (7.0) to day 14 (20.0), rounded half up.
  def interpolated_percent(day)
    exact = Rational(7) + Rational((day - 2) * 13, 12)
    (exact * 10 + Rational(1, 2)).floor / 10.0
  end

  test "the configured table is the straight line between day 2 and day 14, recomputed here" do
    table = Game::Config.current.ramp_bps
    assert_equal 14, table.size
    (3..13).each do |day|
      assert_equal (interpolated_percent(day) * 100).round, table[day - 1], "day #{day}"
    end
  end

  test "the anchors: day 1 is 5.0%, day 2 is 7.0%, day 14 is 20.0%" do
    assert_equal 500, Game::BonusRamp.bps(1)
    assert_equal 700, Game::BonusRamp.bps(2)
    assert_equal 2000, Game::BonusRamp.bps(14)
  end

  test "the intermediate values named in the brief" do
    assert_equal [ 810, 920, 1030, 1130 ], (3..6).map { |day| Game::BonusRamp.bps(day) }
  end

  test "days 1, 2, 3, 13, 14, 15 and 30 against the table" do
    assert_equal [ 500, 700, 810, 1890, 2000, 2000, 2000 ], [ 1, 2, 3, 13, 14, 15, 30 ].map { |day| Game::BonusRamp.bps(day) }
  end

  test "no streak earns no bonus" do
    assert_equal 0, Game::BonusRamp.bps(0)
    assert_equal 0, Game::BonusRamp.bps(-3)
  end

  test "the table never decreases" do
    table = Game::Config.current.ramp_bps
    assert_equal table.sort, table
  end

  test "config validation rejects a table with too much precision, no values or a bad multiplier" do
    base = Rails.application.config_for(:game)
    assert_raises(ArgumentError) { Game::Config.from_hash(base.deep_merge(streaks: { ramp_percent: [ 5.055 ] })) }
    assert_raises(ArgumentError) { Game::Config.from_hash(base.deep_merge(streaks: { ramp_percent: [] })) }
    assert_raises(ArgumentError) { Game::Config.from_hash(base.deep_merge(coins: { deflation_multiplier: 1.5 })) }
    assert_raises(ArgumentError) { Game::Config.from_hash(base.deep_merge(coins: { per_approved_hour: 0 })) }
  end

  test "config values come through as integers" do
    config = Game::Config.current
    assert_equal 10, config.coins_per_hour
    assert_equal 6 * 3600, config.deflation_after_seconds
    assert_equal 800, config.deflation_multiplier_milli
    assert_equal 900, config.quick_seconds
    assert_equal 3600, config.goal_seconds
    assert_equal 6 * 3600, config.grace_seconds
    assert_equal 7, config.freeze_regen_days
  end
end
