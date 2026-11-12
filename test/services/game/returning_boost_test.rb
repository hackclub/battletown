require "test_helper"
require_relative "../../support/coins_helper"

class Game::ReturningBoostTest < ActiveSupport::TestCase
  include CoinsHelper

  D = ->(day) { Date.new(2026, 11, day) }
  CONFIG = Game::ReturningBoost::Config.new(idle_days: 7, boost_days: 3, floor_bps: 1030, max_windows: 3, nudge_max_idle_days: 30)
  # Qualifies on the 1st, then goes quiet for seven days (2nd to 8th), then comes back on the 9th and codes through the 12th.
  BACK = { D[1] => 900, D[9] => 900, D[10] => 900, D[11] => 900, D[12] => 900 }.freeze
  NOW = Time.utc(2026, 11, 13, 12)

  setup do
    @user = build_user(created_on: D[1])
    @source = StubHoursSource.new
  end

  teardown { Game::ReturningBoost::Config.reset! }

  def settle(now = NOW, user: @user) = Game::Settle.call(user, through: now, source: @source)

  def rows(user = @user) = DailyResult.where(user_id: user.id).chronological.index_by(&:local_date)

  def bonuses(user = @user) = rows(user).transform_values(&:bonus_bps)

  # --- config ---

  test "the defaults come from game.yml" do
    config = Game::ReturningBoost.config
    assert_equal [ 7, 3, 1030, 3, 30 ], [ config.idle_days, config.boost_days, config.floor_bps, config.max_windows, config.nudge_max_idle_days ]
    assert_equal Game::BonusRamp.bps(5), config.floor_bps
  end

  test "bad config is refused" do
    assert_raises(ArgumentError) { Game::ReturningBoost::Config.from_hash(returning: { idle_days: 0, boost_days: 3, floor_bps: 1030, max_windows_per_user: 3, nudge_max_idle_days: 30 }) }
    assert_raises(ArgumentError) { Game::ReturningBoost::Config.from_hash(returning: { idle_days: 7, boost_days: 3, floor_bps: 20_000, max_windows_per_user: 3, nudge_max_idle_days: 30 }) }
  end

  # --- the pure rules ---

  test "idle gap counts the whole days between two qualifying days" do
    assert_equal 0, Game::ReturningBoost.idle_gap(D[1], D[2])
    assert_equal 7, Game::ReturningBoost.idle_gap(D[1], D[9])
  end

  test "a window opens only after at least idle_days idle days" do
    assert_nil Game::ReturningBoost.window_starting(D[1], D[8], config: CONFIG)
    window = Game::ReturningBoost.window_starting(D[1], D[9], config: CONFIG)
    assert_equal [ D[9], D[11], 7 ], [ window.starts_on, window.ends_on, window.idle_days ]
  end

  test "no previous qualifying day means no window" do
    assert_nil Game::ReturningBoost.window_starting(nil, D[20], config: CONFIG)
  end

  test "the floor raises low bonuses, never lowers high ones, and leaves zero alone" do
    assert_equal 1030, Game::ReturningBoost.floor(500, in_window: true, config: CONFIG)
    assert_equal 1030, Game::ReturningBoost.floor(1030, in_window: true, config: CONFIG)
    assert_equal 2000, Game::ReturningBoost.floor(2000, in_window: true, config: CONFIG)
    assert_equal 0, Game::ReturningBoost.floor(0, in_window: true, config: CONFIG)
    assert_equal 500, Game::ReturningBoost.floor(500, in_window: false, config: CONFIG)
  end

  test "windows replays a history once per idle period and honours the maximum" do
    found = Game::ReturningBoost.windows([ D[1], D[2], D[12], D[13], D[14], D[24] ], config: CONFIG)
    assert_equal [ D[12], D[24] ], found.map(&:starts_on)
    spread = [ 0, 11, 22, 33, 44 ].map { |offset| Date.new(2026, 1, 1) + offset }
    assert_equal 2, Game::ReturningBoost.windows(spread, config: CONFIG.with(max_windows: 2)).size
  end

  test "window days_left counts today" do
    window = Game::ReturningBoost::Window.new(starts_on: D[9], ends_on: D[11], idle_days: 7)
    assert_equal [ 3, 2, 1, 0, 0 ], [ D[9], D[10], D[11], D[12], D[8] ].map { |day| window.days_left(day) }
  end

  # --- settlement, flag on ---

  test "settlement floors the three days back, opens one window, and the day after pays the plain ramp" do
    with_feature(:returning) do
      @source.seconds = BACK
      settle
      # Day 1 of the first streak is 5%; the freeze covers the 2nd (no bonus); the 9th starts a fresh streak at 1.
      assert_equal [ 500, 0, 1030, 1030, 1030, 920 ], [ D[1], D[2], D[9], D[10], D[11], D[12] ].map { |day| bonuses[day] }
      window = WelcomeBackWindow.find_by!(user: @user)
      assert_equal [ D[9], D[11], 7 ], [ window.starts_on, window.ends_on, window.idle_days ]
      assert_equal 1, WelcomeBackWindow.where(user: @user).count
    end
  end

  test "the streak counters are exactly what they are with the flag off" do
    other = build_user(created_on: D[1])
    @source.seconds = BACK
    on = with_feature(:returning) { settle; rows }
    Game::Settle.call(other, through: NOW, source: @source)
    off = rows(other)

    counters = ->(list) { list.values.map { |row| row.slice(:local_date, :raw_seconds, :quick_met, :goal_met, :freeze_used, :streak_15, :goal_streak, :freeze_available, :days_since_freeze) } }
    assert_equal counters.call(off), counters.call(on)
    assert_equal [ 500, 0, 0, 0, 0, 0, 0, 0, 500, 700, 810, 920 ], off.values.map(&:bonus_bps)
    assert_equal [ 500, 0, 0, 0, 0, 0, 0, 0, 1030, 1030, 1030, 920 ], on.values.map(&:bonus_bps)
  end

  test "with the flag off no window is written and the ramp pays as before" do
    without_feature(:returning) do
      @source.seconds = BACK
      settle
      assert_equal 0, WelcomeBackWindow.count
      assert_equal [ 500, 700, 810, 920 ], [ D[9], D[10], D[11], D[12] ].map { |day| bonuses[day] }
    end
  end

  test "settling again, or a day at a time, changes nothing and keeps one window" do
    with_feature(:returning) do
      @source.seconds = BACK
      settle(Time.utc(2026, 11, 10, 12))
      assert_equal 1, WelcomeBackWindow.count
      settle(Time.utc(2026, 11, 11, 12))
      settle
      assert_empty settle
      assert_equal 1, WelcomeBackWindow.count
      assert_equal [ 1030, 1030, 1030, 920 ], [ D[9], D[10], D[11], D[12] ].map { |day| bonuses[day] }
    end
  end

  test "a missed day inside the window earns nothing and a freeze day is never floored" do
    with_feature(:returning) do
      @source.seconds = { D[1] => 900, D[9] => 900, D[10] => 0, D[11] => 900 }
      settle
      assert_equal 1030, bonuses[D[9]]
      assert_equal 0, bonuses[D[10]]
      assert_equal 1030, bonuses[D[11]]
      # The missed day broke the streak (the freeze was spent on the 2nd): the 11th starts over, and the floor still lifts it.
      assert_equal [ 1, 0, 1 ], [ D[9], D[10], D[11] ].map { |day| rows[day].streak_15 }
    end
  end

  test "six idle days earn no window, seven do" do
    with_feature(:returning) do
      @source.seconds = { D[1] => 900, D[8] => 900 }
      settle
      assert_equal 0, WelcomeBackWindow.count
      assert_equal 500, bonuses[D[8]]

      other = build_user(created_on: D[1])
      @source.seconds = { D[1] => 900, D[9] => 900 }
      Game::Settle.call(other, through: NOW, source: @source)
      assert_equal 1, WelcomeBackWindow.where(user: other).count
    end
  end

  test "signing up and finishing onboarding is not coming back: no earlier qualifying day, no window" do
    with_feature(:returning) do
      @source.seconds = { D[20] => 900 }
      settle(Time.utc(2026, 11, 22, 12))
      assert_equal 0, WelcomeBackWindow.count
      assert_equal 500, bonuses[D[20]]
    end
  end

  test "a second idle period opens a second window, up to the maximum" do
    with_feature(:returning) do
      @source.seconds = { D[1] => 900, D[9] => 900, D[17] => 900, D[25] => 900 }
      Game::ReturningBoost::Config.instance_variable_set(:@current, CONFIG.with(max_windows: 2))
      settle(Time.utc(2026, 11, 27, 12))
      assert_equal [ D[9], D[17] ], WelcomeBackWindow.where(user: @user).order(:starts_on).pluck(:starts_on)
      assert_equal [ 1030, 1030, 500 ], [ D[9], D[17], D[25] ].map { |day| bonuses[day] }
    end
  end

  test "a day outside any window is never touched, even right after one" do
    with_feature(:returning) do
      @source.seconds = BACK.merge(D[13] => 900, D[14] => 900)
      settle(Time.utc(2026, 11, 15, 12))
      # Streak days 4, 5 and 6 pay the plain ramp (9.2%, 10.3%, 11.3%): the floor is gone with the window.
      assert_equal [ 920, 1030, 1130 ], [ D[12], D[13], D[14] ].map { |day| bonuses[day] }
    end
  end

  # --- time zones and DST ---

  test "idle days are local dates: a window across the end of daylight saving time in New York" do
    with_feature(:returning) do
      user = build_user(time_zone: "America/New_York", created_on: Date.new(2026, 10, 25))
      @source.seconds = { Date.new(2026, 10, 28) => 900, Date.new(2026, 11, 5) => 900, Date.new(2026, 11, 6) => 900 }
      # 07:00 New York on the 8th: the 7th is settled, the 8th is not.
      Game::Settle.call(user, through: Time.utc(2026, 11, 8, 12), source: @source)
      window = WelcomeBackWindow.find_by!(user: user)
      assert_equal [ Date.new(2026, 11, 5), Date.new(2026, 11, 7), 7 ], [ window.starts_on, window.ends_on, window.idle_days ]
      assert_equal [ 1030, 1030, 0 ], [ Date.new(2026, 11, 5), Date.new(2026, 11, 6), Date.new(2026, 11, 7) ].map { |day| rows(user)[day].bonus_bps }
    end
  end

  test "a window across the start of daylight saving time in Berlin" do
    with_feature(:returning) do
      user = build_user(time_zone: "Europe/Berlin", created_on: Date.new(2026, 3, 20))
      @source.seconds = { Date.new(2026, 3, 22) => 900, Date.new(2026, 3, 30) => 900 }
      Game::Settle.call(user, through: Time.utc(2026, 4, 2, 12), source: @source)
      assert_equal [ Date.new(2026, 3, 30) ], WelcomeBackWindow.where(user: user).pluck(:starts_on)
      assert_equal 1030, rows(user)[Date.new(2026, 3, 30)].bonus_bps
    end
  end

  # --- paid through the normal approved-ship payout ---

  test "ApproveShip pays the floored bonus, once, only on approved hours" do
    ship = Struct.new(:id) { def self.name = "Ship" }.new(9)
    @source.seconds = { D[1] => 900, D[9] => 3600, D[10] => 3600, D[11] => 3600 }
    pay = lambda do |user|
      Coins::ApproveShip.call(user: user, ship_reference: ship, approved_seconds: 3 * 3600, window_dates: D[9]..D[11], source: @source, now: NOW)
    end

    boosted = with_feature(:returning) { pay.call(@user) }
    # 10 coins an hour for 3 hours = 30; bonus 3 x 10.3% of 10 = 3.09 coins (total 33).
    assert_equal [ 30, 3, 33 ], [ boosted.base_coins, boosted.bonus_coins, boosted.total_coins ]
    assert_equal 33, Coins::Balance.total(@user)
    again = with_feature(:returning) { pay.call(@user) }
    assert again.already_approved
    assert_equal 33, Coins::Balance.total(@user)

    plain_user = build_user(created_on: D[1])
    plain = without_feature(:returning) { pay.call(plain_user) }
    # 5%, 7%, 8.1%: 2.01 coins, total 32.
    assert_equal [ 30, 2, 32 ], [ plain.base_coins, plain.bonus_coins, plain.total_coins ]
  end

  test "unapproved time earns nothing: a boosted day with no approved hours pays no coins" do
    with_feature(:returning) do
      @source.seconds = { D[1] => 900, D[9] => 3600 }
      settle
      assert_equal 0, CoinTransaction.where(user: @user).count
    end
  end

  # --- cascade ---

  test "windows go with the user" do
    WelcomeBackWindow.create!(user: @user, starts_on: D[9], ends_on: D[11], idle_days: 7)
    assert_difference -> { WelcomeBackWindow.count }, -1 do
      User.where(id: @user.id).delete_all
    end
  end

  test "the database refuses a second window with the same start and an end before the start" do
    WelcomeBackWindow.create!(user: @user, starts_on: D[9], ends_on: D[11], idle_days: 7)
    assert_raises(ActiveRecord::RecordNotUnique) do
      ActiveRecord::Base.transaction(requires_new: true) { WelcomeBackWindow.new(user: @user, starts_on: D[9], ends_on: D[11], idle_days: 7).save!(validate: false) }
    end
    assert_raises(ActiveRecord::CheckViolation) do
      ActiveRecord::Base.transaction(requires_new: true) { WelcomeBackWindow.new(user: @user, starts_on: D[15], ends_on: D[14], idle_days: 7).save!(validate: false) }
    end
  end
end
