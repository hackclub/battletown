require "test_helper"

# The "Returning users" panel on /admin/metrics (feature flag `returning`): weekly aggregates, admins only.
class AdminReturningMetricsTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    @original_env = ENV["ADMIN_HCA_UIDS"]
    @detailed = Rails.application.env_config["action_dispatch.show_detailed_exceptions"]
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = false
    @admin = users(:onboarded)
    @teen = users(:new_user)
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = @detailed
    @original_env.nil? ? ENV.delete("ADMIN_HCA_UIDS") : ENV["ADMIN_HCA_UIDS"] = @original_env
  end

  def sign_in_as(user)
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
  end

  def seed_rows(today)
    WelcomeBackWindow.create!(user: @teen, starts_on: today, ends_on: today + 2, idle_days: 7)
    WelcomeBackWindow.create!(user: @admin, starts_on: today - 8, ends_on: today - 6, idle_days: 9)
    Notification.create!(user: @teen, kind: "returning_nudge", status: "sent", scheduled_for: Time.current, due_at: Time.current, sent_at: Time.current,
                         subject_id: 1, idempotency_key: "metrics-nudge-1")
    Notification.create!(user: @admin, kind: "returning_nudge", status: "pending", scheduled_for: Time.current, due_at: Time.current,
                         subject_id: 1, idempotency_key: "metrics-nudge-2")
  end

  test "the aggregates count windows and sent nudges per week, nothing else" do
    today = Time.current.utc.to_date
    seed_rows(today)
    panel = ReturningMetrics.call(today: today)
    assert_equal ReturningMetrics::WEEKS, panel.weeks.size
    assert_equal [ 2, 1 ], [ panel.windows_total, panel.nudges_total ]
    assert_equal 1, panel.weeks.sum(&:nudges_sent)
    assert_equal 2, panel.weeks.sum(&:windows_started)
    assert panel.weeks.last.partial || panel.weeks.last.ends_on == today
    assert_equal 1, panel.weeks.last.nudges_sent
  end

  test "an admin sees the panel while the flag is on, with no names or ids" do
    seed_rows(Time.current.utc.to_date)
    ENV["ADMIN_HCA_UIDS"] = @admin.hca_uid
    sign_in_as @admin
    with_feature(:returning) do
      get admin_metrics_path
      assert_response :success
      assert_select "h2#metrics-returning", "Returning users"
      assert_select "table caption", /Welcome-back windows and nudges per week/
      assert_no_match(/#{Regexp.escape(@teen.display_name)}|#{Regexp.escape(@teen.email)}/, response.body.split("metrics-returning").last)
    end
  end

  test "with the flag off the panel is not there" do
    ENV["ADMIN_HCA_UIDS"] = @admin.hca_uid
    sign_in_as @admin
    without_feature(:returning) do
      get admin_metrics_path
      assert_response :success
      assert_select "#metrics-returning", 0
      assert_no_match(/Returning users|welcome-back/i, response.body)
    end
  end

  test "a signed-in teen gets the same 404 as an unknown page" do
    ENV["ADMIN_HCA_UIDS"] = @admin.hca_uid
    sign_in_as @teen
    with_feature(:returning) do
      get admin_metrics_path
      assert_response :not_found
    end
  end
end
