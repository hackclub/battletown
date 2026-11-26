require "test_helper"
require_relative "../support/ships_test_support"

# The welcome-back banner and the boosted bonus figures the dashboard presenter hands out (feature flag `returning`). The page
# itself no longer draws them, so the figures are read from Dashboard::Presenter after a real dashboard visit (which settles).
class ReturningDashboardTest < ActionDispatch::IntegrationTest
  include ShipsTestSupport

  setup do
    travel_to Time.utc(2026, 11, 16, 15) # midday UTC: what "today" and "settled" mean must not depend on the hour the suite runs
    OmniAuth.config.test_mode = true
    @user = users(:onboarded)
    @today = Hours::Days.today(@user)
    @user.update_columns(created_at: (@today - 30).in_time_zone("UTC"), signed_up_on: @today - 30)
  end

  teardown do
    travel_back
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
  end

  def dashboard
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: @user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
    get dashboard_path
    assert_response :success
    Dashboard::Presenter.new(user: @user.reload)
  end

  test "the day the person comes back, the banner says the boost is on" do
    code(@user, @today - 10, 900)
    code(@user, @today, 900)
    with_feature(:returning) do
      banner = dashboard.returning_banner
      assert_equal "Welcome back!", banner.title
      assert_equal 3, banner.days_left
      assert_match(/boosted for 3 more days/, banner.message)
      assert_match(/at least 10\.3%/, banner.message)
    end
  end

  test "the next day, once the first day back has settled, it counts the days left" do
    code(@user, @today - 11, 900)
    code(@user, @today - 1, 900)
    code(@user, @today, 900)
    with_feature(:returning) do
      banner = dashboard.returning_banner
      assert_equal @today - 1, WelcomeBackWindow.find_by!(user: @user).starts_on
      assert_match(/boosted for 2 more days/, banner.message)
    end
  end

  test "an idle person who has not coded yet sees the boosted figure but no banner" do
    code(@user, @today - 10, 900)
    with_feature(:returning) do
      presenter = dashboard
      assert_nil presenter.returning_banner
      assert_match(/10\.3%/, presenter.quick_streak.today_bonus_text)
    end
  end

  test "an active person sees no banner and the plain ramp" do
    (1..5).each { |ago| code(@user, @today - ago, 900) }
    with_feature(:returning) do
      presenter = dashboard
      assert_nil presenter.returning_banner
      assert_match(/11\.3%/, presenter.quick_streak.today_bonus_text) # day 6 of a real streak: the plain ramp, no floor involved
    end
  end

  test "with the flag off the page shows nothing about it and no window is written" do
    code(@user, @today - 11, 900)
    code(@user, @today - 1, 900)
    code(@user, @today, 900)
    without_feature(:returning) do
      presenter = dashboard
      assert_nil presenter.returning_banner
      assert_equal 0, WelcomeBackWindow.count
      assert_match(/Today's bonus: 7%/, presenter.quick_streak.today_bonus_text)
    end
  end

  test "the idle person's projected figure is the plain ramp with the flag off" do
    code(@user, @today - 10, 900)
    without_feature(:returning) do
      assert_match(/Today's bonus: 5%/, dashboard.quick_streak.today_bonus_text)
    end
  end
end
