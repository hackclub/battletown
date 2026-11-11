require "test_helper"
require_relative "../../support/notifications_helper"

# Notifications are personal data: they appear in the self-service export and vanish with the account.
class Notifications::AccountDataTest < ActiveSupport::TestCase
  include NotificationsHelper

  DUE = Time.utc(2026, 11, 11, 18, 30)

  setup do
    @user = create_user
    @row = Notifications::Scheduler.schedule_next(@user, now: DUE - 6.hours)
  end

  test "the notifications table is registered in the export registry" do
    assert_includes AccountData.sources.map(&:table), "notifications"
    assert_empty AccountData.problems
  end

  test "the export contains the person's notifications without internal ids, message text or Slack id" do
    export = AccountExport.new(@user).as_json
    rows = export.dig("data", "notifications")
    assert_equal 1, rows.size
    row = rows.first
    assert_equal "daily_reminder", row["kind"]
    assert_equal "pending", row["status"]
    assert_equal "2026-11-11T18:30:00Z", row["scheduled_for"]
    assert_not_includes row.keys, "id"
    assert_not_includes row.keys, "user_id"
    assert_not_includes JSON.generate(rows), @user.slack_id
  end

  test "another person's notifications are never in the export" do
    other = create_user
    Notifications::Scheduler.schedule_next(other, now: DUE - 6.hours)
    assert_equal 1, AccountExport.new(@user).as_json.dig("data", "notifications").size
  end

  test "deleting the account removes the notifications" do
    other = create_user
    Notifications::Scheduler.schedule_next(other, now: DUE - 6.hours)
    AccountDeletion.call(@user)
    assert_equal [ other.id ], Notification.pluck(:user_id)
  end
end
