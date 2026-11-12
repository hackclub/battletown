require "test_helper"

class Bosses::BossMathTest < ActiveSupport::TestCase
  M = Bosses::BossMath
  HP = 500 * 3600

  test "damage is the sum, never negative" do
    assert_equal 1_234, M.damage(1_234)
    assert_equal 0, M.damage(0)
    assert_equal 0, M.damage(-500)
  end

  test "exact HP defeats the boss at 100%" do
    assert M.defeated?(HP, HP)
    assert_equal 100, M.percent(HP, HP)
    assert_equal 1.0, M.ratio(HP, HP)
    assert_equal 0, M.remaining(HP, HP)
    assert_equal 0, M.overkill(HP, HP)
  end

  test "one second short is not defeated and shows 99%" do
    assert_not M.defeated?(HP - 1, HP)
    assert_equal 99, M.percent(HP - 1, HP)
    assert_equal 1, M.remaining(HP - 1, HP)
    assert_equal 0, M.overkill(HP - 1, HP)
    assert_operator M.ratio(HP - 1, HP), :<, 1.0
  end

  test "overkill is shown, but percent and ratio stay capped" do
    assert M.defeated?(HP + 5_400, HP)
    assert_equal 100, M.percent(HP + 5_400, HP)
    assert_equal 100, M.percent(HP * 10, HP)
    assert_equal 1.0, M.ratio(HP * 10, HP)
    assert_equal 5_400, M.overkill(HP + 5_400, HP)
    assert_equal 0, M.remaining(HP + 5_400, HP)
  end

  test "36 seconds and a whole hour on 500 hours are both 0%" do
    assert_equal 0, M.percent(36, HP)
    assert_equal 0, M.percent(3_600, HP)
    assert_equal 0, M.percent(3_600 * 4 + 3_599, HP)
    assert_equal 1, M.percent(3_600 * 5, HP)
  end

  test "percent is a floor, not a rounding" do
    assert_equal 62, M.percent(HP * 62 / 100 + 17, HP)
    assert_equal 99, M.percent((HP * 995) / 1000, HP)
  end

  test "a boss with 1 second of health" do
    assert_not M.defeated?(0, 1)
    assert_equal 0, M.percent(0, 1)
    assert M.defeated?(1, 1)
    assert_equal 100, M.percent(1, 1)
    assert_equal 1.0, M.ratio(1, 1)
    assert_equal 0, M.remaining(1, 1)
    assert_equal 4, M.overkill(5, 1)
  end

  test "nothing is dealt yet" do
    assert_equal 0, M.percent(0, HP)
    assert_equal 0.0, M.ratio(0, HP)
    assert_equal HP, M.remaining(0, HP)
  end
end
