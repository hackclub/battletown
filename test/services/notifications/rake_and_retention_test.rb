require "test_helper"
require "rake"
require_relative "../../support/notifications_helper"

class Notifications::RakeAndRetentionTest < ActiveSupport::TestCase
  include NotificationsHelper

  DUE = Time.utc(2026, 11, 11, 18, 30)

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("notifications:dispatch")
  end

  def run_task(name)
    task = Rake::Task[name]
    task.reenable
    out, = capture_io { task.invoke }
    out
  end

  test "notifications:dispatch reports the kill switch state and sends when enabled" do
    user = create_user
    row = Notifications::Scheduler.schedule_next(user, now: DUE - 6.hours)
    travel_to DUE + 1.minute do
      assert_includes with_env("NOTIFICATIONS_ENABLED" => nil) { run_task("notifications:dispatch") }, "enabled=false"
      assert row.reload.pending?
      assert_includes with_env("NOTIFICATIONS_ENABLED" => "true") { run_task("notifications:dispatch") }, "sent=1"
      assert row.reload.sent?
    end
  end

  test "notifications:schedule_all queues onboarded users with a Slack id, and is safe to repeat" do
    eligible = create_user
    create_user(slack_id: nil)
    create_user(onboarded_at: nil)
    run_task("notifications:schedule_all")
    run_task("notifications:schedule_all")
    assert_equal [ eligible.id ], Notification.pending.pluck(:user_id)
  end

  test "prune deletes only finished rows older than the retention period" do
    user = create_user
    old_sent = Notification.create!(user: user, kind: "daily_reminder", status: "sent", scheduled_for: DUE, due_at: DUE,
                                    idempotency_key: "k1", updated_at: 100.days.ago)
    recent_sent = Notification.create!(user: user, kind: "daily_reminder", status: "sent", scheduled_for: DUE, due_at: DUE,
                                       idempotency_key: "k2")
    old_pending = Notification.create!(user: user, kind: "daily_reminder", status: "pending", scheduled_for: DUE, due_at: DUE,
                                       idempotency_key: "k3", updated_at: 100.days.ago)
    Notification.where(id: [ old_sent.id, old_pending.id ]).update_all(updated_at: 100.days.ago)

    assert_equal 1, Notifications::Retention.prune
    assert_not Notification.exists?(old_sent.id)
    assert Notification.exists?(recent_sent.id)
    assert Notification.exists?(old_pending.id)
  end
end
