require "test_helper"
require_relative "../../support/notifications_helper"

class Notifications::SchedulerTest < ActiveSupport::TestCase
  include NotificationsHelper

  NOW = Time.utc(2026, 11, 11, 12, 0) # a Wednesday

  setup { @user = create_user } # onboarded, all days, 18:30 UTC, Slack id present

  def schedule(user = @user, now: NOW) = Notifications::Scheduler.schedule_next(user, now: now)

  test "inserts the next reminder with a deterministic idempotency key" do
    row = schedule
    assert row.pending?
    assert_equal "daily_reminder", row.kind
    assert_equal "slack_dm", row.channel
    assert_equal Time.utc(2026, 11, 11, 18, 30), row.scheduled_for
    assert_equal row.scheduled_for, row.due_at
    assert_equal 0, row.attempts
    assert_equal "daily_reminder:#{@user.id}:2026-11-11T18:30:00Z", row.idempotency_key
  end

  test "is idempotent: scheduling twice makes one row" do
    first = schedule
    assert_no_difference -> { Notification.count } do
      assert_equal first.id, schedule.id
      assert_equal first.id, schedule(now: NOW + 5.minutes).id
    end
  end

  test "stores no message text or contact details" do
    schedule
    columns = Notification.column_names
    assert_empty columns & %w[body text message content slack_id email]
  end

  test "nothing is scheduled for users who are not eligible" do
    assert_nil schedule(create_user(onboarded_at: nil))
    assert_nil schedule(create_user(slack_id: nil))
    assert_nil schedule(create_user(slack_id: ""))
    assert_nil schedule(create_user(coding_days: 0))
    assert_nil schedule(create_user(coding_time: nil))
    assert_nil schedule(create_user(time_zone: nil))
    assert_equal 0, Notification.count
  end

  test "removing the schedule cancels the pending reminder" do
    row = schedule
    @user.update!(coding_days: 0)
    assert_nil schedule
    assert row.reload.cancelled?
    assert_equal 0, Notification.pending.count
  end

  test "changing the schedule cancels the old reminder and queues the new one" do
    old = schedule
    @user.update!(coding_time: "20:00")
    fresh = schedule
    assert_not_equal old.id, fresh.id
    assert old.reload.cancelled?
    assert_equal Time.utc(2026, 11, 11, 20, 0), fresh.scheduled_for
    assert_equal [ fresh.id ], Notification.pending.pluck(:id)
  end

  test "going back to a previous schedule revives the cancelled row instead of colliding with its key" do
    original = schedule
    @user.update!(coding_time: "20:00")
    schedule
    @user.update!(coding_time: "18:30")
    again = schedule
    assert_equal original.id, again.id
    assert again.pending?
    assert_equal [ original.id ], Notification.pending.pluck(:id)
  end

  test "a reminder that was already sent is never queued again" do
    row = schedule
    row.update!(status: "sent", sent_at: NOW)
    assert_no_difference -> { Notification.count } do
      assert_equal row.id, schedule(now: NOW + 1.minute).id
    end
    assert_equal 0, Notification.pending.count
  end

  test "losing a race to another scheduler returns the winner's row" do
    winner = schedule
    key = winner.idempotency_key
    assert_equal winner.id, Notifications::Scheduler.create_or_find(@user, winner.scheduled_for, key).id
  end

  test "a different pending row for the same user is replaced, never duplicated" do
    schedule
    assert_equal 1, Notification.where(user: @user).pending.count
    schedule(now: NOW + 7.hours) # past 18:30 today, so the next one is tomorrow
    assert_equal 1, Notification.where(user: @user).pending.count
    assert_equal Time.utc(2026, 11, 12, 18, 30), Notification.pending.sole.scheduled_for
  end

  test "uses the user's own time zone" do
    user = create_user(time_zone: "Eastern Time (US & Canada)", coding_days: 64) # Sunday 18:30 EST
    assert_equal Time.utc(2026, 11, 15, 23, 30), schedule(user).scheduled_for
  end
end
