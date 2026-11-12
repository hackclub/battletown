require "test_helper"
require_relative "../support/notifications_helper"

# The daily reminder is queued when onboarding finishes and whenever the schedule or Slack id changes.
class ReminderWiringTest < ActionDispatch::IntegrationTest
  include NotificationsHelper

  setup { OmniAuth.config.test_mode = true }

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
  end

  # Signing in copies the Slack id from Hack Club Auth, so the claims carry it (or not) like the real thing.
  def sign_in_as(user, extra: nil)
    extra ||= user.slack_id ? { "slack_id" => user.slack_id } : {}
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: extra })
    post "/auth/hack_club"
    follow_redirect!
  end

  def step(name, params = {}) = patch(onboarding_step_path(name), params: { user: params })

  def pending_for(user) = Notification.pending.where(user_id: user.id, kind: "daily_reminder")

  def walk_to_celebrate(user)
    step("prize", prize_key: "tshirt")
    step("project", project_kind: "game", project_idea: "A farming game")
    step("schedule", coding_day_names: %w[monday friday], coding_time: "18:30", time_zone: "UTC")
    step("account")
    assert_equal onboarding_step_path("celebrate"), path_from(response)
    user.reload
  end

  def path_from(response) = URI(response.location).path

  test "finishing onboarding queues the first reminder" do
    user = users(:new_user)
    user.update_columns(slack_id: "UTESTNEW01")
    sign_in_as(user)
    walk_to_celebrate(user)
    assert_not user.onboarded?
    assert_equal 0, pending_for(user).count, "nothing before onboarding is finished"

    step("celebrate")
    assert_redirected_to dashboard_path
    assert user.reload.onboarded?
    row = pending_for(user).sole
    assert_includes [ 1, 5 ], row.scheduled_for.utc.wday, "a Monday or a Friday"
    assert_equal "18:30", row.scheduled_for.utc.strftime("%H:%M")

    step("celebrate")
    assert_equal 1, pending_for(user).count, "a second submit makes no second row"
  end

  test "finishing onboarding without a Slack id queues nothing and still works" do
    user = users(:new_user)
    sign_in_as(user)
    walk_to_celebrate(user)
    step("celebrate")
    assert_redirected_to dashboard_path
    assert_equal 0, pending_for(user).count
  end

  test "changing the coding time or days moves the queued reminder" do
    user = users(:onboarded)
    user.update_columns(slack_id: "UTESTONB01")
    Notifications::Scheduler.schedule_next(user)
    before = pending_for(user).sole
    sign_in_as(user)

    step("schedule", coding_day_names: User::DAYS, coding_time: "09:15", time_zone: "UTC")
    assert_redirected_to dashboard_path
    after = pending_for(user).sole
    assert_equal "09:15", after.scheduled_for.utc.strftime("%H:%M")
    assert_not_equal before.id, after.id
    assert before.reload.cancelled?

    step("schedule", coding_day_names: User::DAYS, coding_time: "09:15", time_zone: "Pacific Time (US & Canada)")
    assert_equal 1, pending_for(user).count
    assert_not_equal after.scheduled_for, pending_for(user).sole.scheduled_for
  end

  test "an invalid schedule change does not touch the queue" do
    user = users(:onboarded)
    user.update_columns(slack_id: "UTESTONB02")
    Notifications::Scheduler.schedule_next(user)
    before = pending_for(user).sole
    sign_in_as(user)
    step("schedule", coding_day_names: User::DAYS, coding_time: "not a time", time_zone: "UTC")
    assert_response :unprocessable_content
    assert_equal before.id, pending_for(user).sole.id
  end

  test "signing in with a new Slack id queues the reminder, and signing in again changes nothing" do
    user = users(:onboarded)
    assert_nil user.slack_id
    sign_in_as(user, extra: { "slack_id" => "UTESTONB03" })
    assert_equal "UTESTONB03", user.reload.slack_id
    row = pending_for(user).sole

    sign_in_as(user, extra: { "slack_id" => "UTESTONB03" })
    assert_equal [ row.id ], pending_for(user).pluck(:id)
  end

  test "a scheduler failure never breaks onboarding or sign-in" do
    original = Notifications::Scheduler.method(:schedule_next)
    Notifications::Scheduler.define_singleton_method(:schedule_next) { |*, **| raise "boom" }
    user = users(:onboarded)
    logs = capture_logs do
      sign_in_as(user, extra: { "slack_id" => "UTESTONB04" })
      assert_redirected_to dashboard_path
      step("schedule", coding_day_names: User::DAYS, coding_time: "10:00", time_zone: "UTC")
      assert_redirected_to dashboard_path
    end
    assert_equal "10:00", user.reload.coding_time
    assert_includes logs, "notifications.schedule_failed error=RuntimeError"
  ensure
    Notifications::Scheduler.define_singleton_method(:schedule_next, original)
  end
end
