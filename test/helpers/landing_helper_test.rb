require "test_helper"

class LandingHelperTest < ActionView::TestCase
  test "says join the fight below the threshold" do
    assert_equal "Join the fight", join_cta_label(0)
    assert_equal "Join the fight", join_cta_label(LandingHelper::FIGHTER_COUNT_THRESHOLD - 1)
  end

  test "quotes the real count from the threshold up" do
    assert_equal "Join 10 other fighters", join_cta_label(10)
    assert_equal "Join 1,234 other fighters", join_cta_label(1234)
  end

  test "uses the real user count by default" do
    (User.count...LandingHelper::FIGHTER_COUNT_THRESHOLD).each { |i| User.create!(hca_uid: "ident!helper#{i}") }
    assert_equal "Join #{User.count} other fighters", join_cta_label
  end

  test "the threshold is ten" do
    assert_equal 10, LandingHelper::FIGHTER_COUNT_THRESHOLD
  end
end
