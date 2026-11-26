require "test_helper"

class AnalyticsBucketsTest < ActiveSupport::TestCase
  test "every bucket it returns is an allowed enum value" do
    allowed = Analytics::Events.config[:buckets]
    [ 0, 1, 3599, 3600, 7199, 7200, 17_999, 18_000, 35_999, 36_000, 360_000 ].each { |seconds| assert_includes allowed[:hours_bucket], Analytics::Buckets.hours(seconds) }
    [ 0, 1, 2, 3, 4, 6, 7, 13, 14, 90 ].each { |count| assert_includes allowed[:days_bucket], Analytics::Buckets.days(count) }
    [ 0, 1, 2, 3, 9 ].each { |count| assert_includes allowed[:nth], Analytics::Buckets.nth(count) }
    now = Time.current
    [ 0, 1.hour, 25.hours, 49.hours, 30.days ].each { |ago| assert_includes allowed[:waited], Analytics::Buckets.waited(now - ago, now) }
  end

  test "hours include their lower bound" do
    assert_equal "lt1", Analytics::Buckets.hours(3599)
    assert_equal "1-2", Analytics::Buckets.hours(3600)
    assert_equal "2-5", Analytics::Buckets.hours(7200)
    assert_equal "5-10", Analytics::Buckets.hours(18_000)
    assert_equal "10plus", Analytics::Buckets.hours(36_000)
  end

  test "days, nth and waited" do
    assert_equal %w[1 1 2-3 2-3 4-6 7-13 14plus], [ 0, 1, 2, 3, 4, 7, 14 ].map { |count| Analytics::Buckets.days(count) }
    assert_equal %w[1 2 3plus], [ 1, 2, 3 ].map { |count| Analytics::Buckets.nth(count) }
    now = Time.current
    assert_equal %w[same_day 1d 2d 3plus_d], [ 2.hours, 30.hours, 50.hours, 5.days ].map { |ago| Analytics::Buckets.waited(now - ago, now) }
  end
end
