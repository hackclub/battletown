require "test_helper"
require_relative "../support/email_helper"

# /admin/email: aggregate email row counts per week and status. Orange admin tool, admins only, behind the flag.
class AdminEmailTest < ActionDispatch::IntegrationTest
  include EmailHelper

  setup do
    OmniAuth.config.test_mode = true
    @detailed = Rails.application.env_config["action_dispatch.show_detailed_exceptions"]
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = false
    @original_admins = ENV["ADMIN_HCA_UIDS"]
    @admin = users(:onboarded)
    ENV["ADMIN_HCA_UIDS"] = @admin.hca_uid
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = @detailed
    @original_admins.nil? ? ENV.delete("ADMIN_HCA_UIDS") : ENV["ADMIN_HCA_UIDS"] = @original_admins
  end

  def sign_in_as(user)
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
  end

  TODAY = Time.utc(2026, 11, 12, 12) # a Thursday: the last day of the week that began Friday 6 November

  test "weekly counts group rows by the Friday-to-Thursday week of creation and by status" do
    user = create_email_user("adm1")
    travel_to(TODAY) do
      this_week = [ [ "sent", Time.utc(2026, 11, 9) ], [ "sent", Time.utc(2026, 11, 12, 8) ], [ "skipped", Time.utc(2026, 11, 6, 0, 1) ], [ "pending", Time.utc(2026, 11, 11) ] ]
      last_week = [ [ "cancelled", Time.utc(2026, 11, 5, 23, 59) ], [ "failed", Time.utc(2026, 10, 30) ] ]
      (this_week + last_week).each { |status, at| email_row(user, status: status).update_columns(created_at: at) }
      Notification.create!(user: user, kind: "ship_approved", channel: "slack_dm", status: "sent", subject_id: 1, scheduled_for: TODAY, due_at: TODAY, idempotency_key: "slack:adm:1")

      weeks = Notifications::Email::Stats.weekly(today: TODAY.to_date)
      assert_equal 8, weeks.size
      current, previous = weeks.first(2)
      assert_equal [ Date.new(2026, 11, 6), Date.new(2026, 11, 12), true ], [ current.starts_on, current.ends_on, current.partial ]
      assert_equal({ "sent" => 2, "skipped" => 1, "pending" => 1 }, current.counts)
      assert_equal 4, current.total
      assert_equal Date.new(2026, 10, 30), previous.starts_on
      assert_equal({ "cancelled" => 1, "failed" => 1 }, previous.counts)
      assert_equal 0, weeks.last.total
    end
  end

  test "the page is a 404 while the flag is off, and for signed-out visitors and non-admins" do
    get "/admin/email"
    assert_response :not_found

    sign_in_as @admin
    get "/admin/email"
    assert_response :not_found, "flag off"

    with_feature(:email) do
      delete logout_path
      get "/admin/email"
      assert_response :not_found
      sign_in_as users(:new_user)
      get "/admin/email"
      assert_response :not_found
    end
  end

  test "an admin sees the counts in an orange admin tool, with no address, name or id, and a link from the dashboard" do
    user = create_email_user("adm2", email: "never.shown@example.test", display_name: "Never Shown")
    email_row(user, status: "sent")
    email_row(user, status: "cancelled")

    with_feature(:email) do
      sign_in_as @admin
      get "/admin"
      assert_select "a[href='/admin/email']", "Email"

      get "/admin/email"
      assert_response :success
      assert_select "div.admin-only"
      assert_select "table caption", "Email rows by week and status"
      assert_select "tbody tr:first-child td.num", minimum: 5
      assert_not_includes response.body, "never.shown@example.test"
      assert_not_includes response.body, "Never Shown"
      assert_not_includes response.body, user.hca_uid
      assert_equal "no-store", response.headers["Cache-Control"]
    end
  end

  test "the dashboard has no email link while the flag is off" do
    sign_in_as @admin
    get "/admin"
    assert_select "a[href='/admin/email']", 0
  end
end
