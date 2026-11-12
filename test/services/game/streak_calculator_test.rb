require "test_helper"

class Game::StreakCalculatorTest < ActiveSupport::TestCase
  Calc = Game::StreakCalculator
  QUICK = 900
  GOAL = 3600

  def replay(*seconds) = Calc.replay(seconds)

  def streaks(results) = results.map { |r| r.state.streak_15 }

  test "899 seconds is a miss and 900 seconds counts" do
    assert_not replay(899).first.quick_met
    assert replay(900).first.quick_met
    assert_equal 0, replay(899).first.bonus_bps
    assert_equal 500, replay(900).first.bonus_bps
  end

  test "the goal needs 3600 seconds, 3599 does not count" do
    assert_not replay(3599).first.goal_met
    assert replay(3600).first.goal_met
    assert replay(3599).first.quick_met
  end

  test "bonus follows the ramp on streak days 1, 2, 3, 13, 14, 15 and 30" do
    results = Calc.replay([ QUICK ] * 30)
    bonuses = results.map(&:bonus_bps)
    assert_equal [ 500, 700, 810 ], bonuses.first(3)
    assert_equal 1890, bonuses[12]
    assert_equal 2000, bonuses[13]
    assert_equal 2000, bonuses[14]
    assert_equal 2000, bonuses[29]
    assert_equal (1..30).to_a, streaks(results)
  end

  test "a miss resets the streak and the next qualifying day is day 1 at 5%" do
    results = Calc.replay([ QUICK ] * 5 + [ 0 ] + [ 0 ] + [ QUICK ])
    # Day 6 is covered by the freeze, day 7 is a second miss with no freeze left: reset.
    assert_equal [ 1, 2, 3, 4, 5, 5, 0, 1 ], streaks(results)
    assert_equal 500, results.last.bonus_bps
  end

  test "a miss with no streak and an available freeze does not consume the freeze" do
    results = replay(0, 0, 0)
    assert results.all? { |r| !r.freeze_used }
    assert results.last.state.freeze_available
  end

  test "the freeze protects the first miss: streak kept, no increment, no bonus" do
    results = replay(QUICK, QUICK, QUICK, 0, QUICK)
    frozen = results[3]
    assert frozen.freeze_used
    assert_not frozen.quick_met
    assert_equal 0, frozen.bonus_bps
    assert_equal 3, frozen.state.streak_15
    assert_not frozen.state.freeze_available
    assert_equal 4, results[4].state.streak_15
    assert_equal BonusRampBps = Game::BonusRamp.bps(4), results[4].bonus_bps
  end

  test "the freeze is consumed once: a second miss resets" do
    results = replay(QUICK, QUICK, 0, 0, QUICK)
    assert_equal [ true, false ], results[2..3].map(&:freeze_used)
    assert_equal [ 2, 0 ], streaks(results[2..3])
    assert_equal 1, results[4].state.streak_15
  end

  test "the freeze is re-earned after 7 consecutive qualifying days since it was used" do
    results = Calc.replay([ QUICK, 0 ] + [ QUICK ] * 7)
    assert results[1].freeze_used
    # Qualifying days after the freeze: 6 days, still spent; the 7th re-earns it.
    assert_equal [ false ] * 6, results[2..7].map { |r| r.state.freeze_available }
    assert_equal [ 1, 2, 3, 4, 5, 6 ], results[2..7].map { |r| r.state.days_since_freeze }
    assert results[8].state.freeze_available
    assert_equal 0, results[8].state.days_since_freeze
  end

  test "a frozen day does not count toward re-earning and a reset restarts the count" do
    results = Calc.replay([ QUICK, 0, QUICK, QUICK, 0, 0, QUICK ])
    # Day 5 (index 4): freeze spent, streak > 0, so the miss resets and the regen count restarts.
    assert_equal 0, results[4].state.streak_15
    assert_equal 0, results[4].state.days_since_freeze
    assert_not results[4].state.freeze_available
  end

  test "the re-earned freeze is capped at one" do
    results = Calc.replay([ QUICK ] * 40)
    assert results.last.state.freeze_available
    assert_equal 0, results.last.state.days_since_freeze
    # Using it again needs a fresh streak of 7 to earn the next.
    more = Calc.replay([ 0 ] + [ QUICK ] * 6, state: results.last.state)
    assert more.first.freeze_used
    assert_not more.last.state.freeze_available
  end

  test "a new player starts with the freeze available, configurable" do
    assert Calc.initial_state.freeze_available
    config = Game::Config.current.with(freeze_starts_available: false)
    assert_not Calc.initial_state(config: config).freeze_available
    results = Calc.replay([ QUICK, 0 ], config: config)
    assert_not results[1].freeze_used
    assert_equal 0, results[1].state.streak_15
  end

  test "the daily-goal streak is a separate counter with no freeze and no bonus" do
    results = replay(GOAL, GOAL, QUICK, GOAL)
    assert_equal [ 1, 2, 0, 1 ], results.map { |r| r.state.goal_streak }
    # The 15-minute streak was not broken by the day that missed the goal.
    assert_equal [ 1, 2, 3, 4 ], streaks(results)
    # Bonus comes from the 15-minute streak only.
    assert_equal [ 500, 700, 810, 920 ], results.map(&:bonus_bps)
  end

  test "a frozen day still resets the goal streak" do
    results = replay(GOAL, GOAL, 0, GOAL)
    assert results[2].freeze_used
    assert_equal [ 1, 2, 0, 1 ], results.map { |r| r.state.goal_streak }
  end

  test "a goal day always counts as a quick day with the default thresholds" do
    [ 0, 899, 900, 3599, 3600, 40_000 ].each do |seconds|
      result = replay(seconds).first
      assert result.quick_met if result.goal_met
    end
  end

  test "step accepts a Day, an integer, nil and negatives" do
    state = Calc.initial_state
    assert Calc.step(state, Calc::Day.new(raw_seconds: 900)).quick_met
    assert Calc.step(state, 900).quick_met
    assert_not Calc.step(state, nil).quick_met
    assert_not Calc.step(state, -5).quick_met
  end

  test "step does not mutate the state it is given" do
    state = Calc.initial_state
    Calc.step(state, 900)
    assert_equal Calc.initial_state, state
  end

  test "replay from a stored state continues the streak" do
    first = Calc.replay([ QUICK ] * 3)
    rest = Calc.replay([ QUICK ] * 2, state: first.last.state)
    assert_equal Calc.replay([ QUICK ] * 5).last, rest.last
  end
end
