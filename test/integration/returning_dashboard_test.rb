require "test_helper"
require_relative "../support/ships_test_support"

# The welcome-back banner and the boosted bonus figures on the dashboard (feature flag `returning`).
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
  end

  test "the day the person comes back, the banner says the boost is on" do
    code(@user, @today - 10, 900)
    code(@user, @today, 900)
    with_feature(:returning) do
      dashboard
      assert_select ".dash-returning[role=status] .callout__title", "Welcome back!"
      assert_select ".dash-returning", /boosted for 3 more days/
      assert_select ".dash-returning", /at least 10\.3%/
    end
  end

  test "the next day, once the first day back has settled, it counts the days left" do
    code(@user, @today - 11, 900)
    code(@user, @today - 1, 900)
    code(@user, @today, 900)
    with_feature(:returning) do
      dashboard
      assert_equal @today - 1, WelcomeBackWindow.find_by!(user: @user).starts_on
      assert_select ".dash-returning", /boosted for 2 more days/
    end
  end

  test "an idle person who has not coded yet sees the boosted figure but no banner" do
    code(@user, @today - 10, 900)
    with_feature(:returning) do
      dashboard
      assert_select ".dash-returning", 0
      assert_select ".dash-facts__ramp", /10\.3%/
    end
  end

  test "an active person sees no banner and the plain ramp" do
    (1..5).each { |ago| code(@user, @today - ago, 900) }
    with_feature(:returning) do
      dashboard
      assert_select ".dash-returning", 0
      assert_select ".dash-facts__ramp", /11\.3%/ # day 6 of a real streak: the plain ramp, no floor involved
    end
  end

  test "with the flag off the page shows nothing about it and no window is written" do
    code(@user, @today - 11, 900)
    code(@user, @today - 1, 900)
    code(@user, @today, 900)
    without_feature(:returning) do
      dashboard
      assert_select ".dash-returning", 0
      assert_no_match(/Welcome back/, response.body)
      assert_equal 0, WelcomeBackWindow.count
      assert_select ".dash-facts__ramp", /Today's bonus: 7%/
    end
  end

  test "the idle person's projected figure is the plain ramp with the flag off" do
    code(@user, @today - 10, 900)
    without_feature(:returning) do
      dashboard
      assert_select ".dash-facts__ramp", /Today's bonus: 5%/
    end
  end
end
