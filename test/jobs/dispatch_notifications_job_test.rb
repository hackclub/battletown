require "test_helper"
require_relative "../support/notifications_helper"

class DispatchNotificationsJobTest < ActiveJob::TestCase
  include NotificationsHelper

  DUE = Time.utc(2026, 11, 11, 18, 30)

  setup do
    @user = create_user
    @row = Notifications::Scheduler.schedule_next(@user, now: DUE - 6.hours)
  end

  test "enqueues on the default queue" do
    assert_enqueued_with(job: DispatchNotificationsJob, queue: "default") { DispatchNotificationsJob.perform_later }
  end

  test "runs the dispatcher when notifications are enabled (the test environment uses the null adapter)" do
    travel_to DUE + 1.minute do
      with_env("NOTIFICATIONS_ENABLED" => "true") { DispatchNotificationsJob.perform_now }
    end
    assert @row.reload.sent?
  end

  test "does nothing while the kill switch is off" do
    travel_to DUE + 1.minute do
      with_env("NOTIFICATIONS_ENABLED" => nil) { DispatchNotificationsJob.perform_now }
    end
    assert @row.reload.pending?
  end
end
