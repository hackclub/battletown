require "test_helper"

# The Net Promoter Score maths.
class Nps::StatsTest < ActiveSupport::TestCase
  def tally(*scores) = Nps::Stats.tally(scores)

  test "no answers means no NPS, not zero" do
    assert_nil tally.nps
    assert_equal 0, tally.responses
    assert_nil Nps::Stats.overall.nps
  end

  test "all promoters is 100 and all detractors is -100" do
    assert_equal 100, tally(9, 10, 10).nps
    assert_equal(-100, tally(0, 3, 6).nps)
  end

  test "passives count in the total but in neither group" do
    result = tally(7, 8)
    assert_equal [ 0, 2, 0 ], [ result.promoters, result.passives, result.detractors ]
    assert_equal 0, result.nps
    assert_equal 50, tally(10, 8).nps
  end

  test "the band edges: 6 is a detractor, 7 and 8 passive, 9 a promoter" do
    result = tally(6, 7, 8, 9)
    assert_equal [ 1, 2, 1 ], [ result.detractors, result.passives, result.promoters ]
    assert_equal 1, tally(9).promoters
    assert_equal 1, tally(6).detractors
    assert_equal 1, tally(7).passives
    assert_equal 1, tally(8).passives
  end

  test "a mixed set" do
    # 4 promoters, 3 passives, 3 detractors of 10: (4 - 3) / 10 = 10
    assert_equal 10, tally(10, 10, 9, 9, 8, 7, 7, 5, 2, 0).nps
  end

  test "rounding is to a whole number, halves away from zero" do
    assert_equal 33, tally(10, 7, 7).nps   # 33.33
    assert_equal 67, tally(10, 10, 7).nps  # 66.67
    assert_equal(-33, tally(0, 7, 7).nps)
    assert_equal 13, tally(10, 7, 7, 7, 7, 7, 7, 7).nps # 12.5 rounds up
    assert_equal(-13, tally(0, 7, 7, 7, 7, 7, 7, 7).nps)
  end

  test "the trend lists the last 14 UTC days, newest last, with empty days" do
    now = Time.utc(2026, 11, 12, 1)
    user = users(:onboarded)
    NpsResponse.create!(user: user, score: 10, answered_at: Time.utc(2026, 11, 12, 0, 30), prompt_window_date: Date.new(2026, 11, 12))
    NpsResponse.create!(user: user, score: 2, answered_at: Time.utc(2026, 11, 11, 23, 59), prompt_window_date: Date.new(2026, 11, 11))
    NpsResponse.create!(user: user, score: 8, answered_at: Time.utc(2026, 10, 30, 12), prompt_window_date: Date.new(2026, 10, 30))
    NpsResponse.create!(user: user, score: 8, answered_at: Time.utc(2026, 10, 29, 23), prompt_window_date: Date.new(2026, 10, 29)) # 14 days back: outside

    trend = Nps::Stats.trend(now: now)
    assert_equal 14, trend.size
    assert_equal [ Date.new(2026, 10, 30), Date.new(2026, 11, 12) ], [ trend.first.date, trend.last.date ]
    assert_equal [ 1, 1, 1 ], [ trend.first.tally.responses, trend.last.tally.responses, trend[-2].tally.responses ]
    assert_equal 100, trend.last.tally.nps
    assert_equal(-100, trend[-2].tally.nps)
    assert_equal 0, trend[1].tally.responses
    assert_equal 3, trend.sum { |day| day.tally.responses }
  end
end
