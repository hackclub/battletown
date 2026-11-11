require "test_helper"
require_relative "../../support/notifications_helper"

class Notifications::DispatcherTest < ActiveSupport::TestCase
  include NotificationsHelper

  Result = Notifications::Slack::Result
  CONFIG = Notifications::Config.current

  # create_user is onboarded, all days, 18:30 UTC. The first reminder is 2026-11-11 18:30 UTC.
  DUE = Time.utc(2026, 11, 11, 18, 30)
  RUN_AT = DUE + 1.minute

  setup do
    @user = create_user
    @row = Notifications::Scheduler.schedule_next(@user, now: DUE - 6.hours)
    assert_equal DUE, @row.scheduled_for
  end

  def run_dispatcher(adapter, now: RUN_AT, limit: 100, config: CONFIG, enabled: "true")
    with_env("NOTIFICATIONS_ENABLED" => enabled) do
      Notifications::Dispatcher.run(now: now, limit: limit, adapter: adapter, config: config)
    end
  end

  test "does nothing unless NOTIFICATIONS_ENABLED is exactly true" do
    [ nil, "", "false", "1", "yes", "TRUE", "true " ].each do |value|
      adapter = NotificationsHelper::FakeAdapter.new
      summary = run_dispatcher(adapter, enabled: value)
      assert_not summary.enabled, value.inspect
      assert_empty adapter.calls, value.inspect
      assert @row.reload.pending?
      assert_equal 0, @row.attempts
    end
  end

  test "sends a due reminder, records it, and schedules the next day" do
    adapter = NotificationsHelper::FakeAdapter.new
    summary = run_dispatcher(adapter)

    assert_equal 1, summary.sent
    call = adapter.calls.sole
    assert_equal @user.slack_id, call[:slack_id]
    assert_equal CONFIG.template("daily_reminder"), call[:text]
    @row.reload
    assert @row.sent?
    assert_equal RUN_AT, @row.sent_at
    assert_equal 1, @row.attempts
    assert_nil @row.last_error_code

    following = Notification.pending.sole
    assert_equal Time.utc(2026, 11, 12, 18, 30), following.scheduled_for
  end

  test "a reminder that is not due yet is left alone" do
    adapter = NotificationsHelper::FakeAdapter.new
    run_dispatcher(adapter, now: DUE - 1.second)
    assert_empty adapter.calls
    assert @row.reload.pending?
  end

  test "running twice sends once" do
    adapter = NotificationsHelper::FakeAdapter.new
    run_dispatcher(adapter)
    run_dispatcher(adapter)
    assert_equal 1, adapter.calls.size
  end

  test "a retryable failure backs off, honours Retry-After, and eventually succeeds" do
    adapter = NotificationsHelper::FakeAdapter.new(
      Result.failure("ratelimited", retryable: true, retry_after: 300), Result.failure("internal_error", retryable: true),
      Result.success
    )
    summary = run_dispatcher(adapter)
    assert_equal 1, summary.retried
    @row.reload
    assert @row.pending?
    assert_equal 1, @row.attempts
    assert_equal "ratelimited", @row.last_error_code
    assert_equal RUN_AT + 300, @row.due_at # Retry-After (300) beats the 60 second backoff

    run_dispatcher(adapter, now: RUN_AT + 299)
    assert_equal 1, adapter.calls.size # still waiting

    run_dispatcher(adapter, now: RUN_AT + 300)
    @row.reload
    assert_equal 2, @row.attempts
    assert_equal "internal_error", @row.last_error_code
    assert_equal RUN_AT + 300 + 120, @row.due_at # second attempt waits 120 seconds

    run_dispatcher(adapter, now: @row.due_at)
    assert @row.reload.sent?
    assert_equal 3, @row.attempts
    assert_nil @row.last_error_code
    assert_equal 3, adapter.calls.size
  end

  test "retries stop at max_attempts, the row fails and tomorrow's reminder is scheduled" do
    config = CONFIG.with(max_attempts: 2, backoff_base: 10)
    adapter = NotificationsHelper::FakeAdapter.new(Result.failure("internal_error", retryable: true))
    run_dispatcher(adapter, config: config)
    run_dispatcher(adapter, config: config, now: RUN_AT + 10)

    @row.reload
    assert @row.failed?
    assert_equal 2, @row.attempts
    assert_equal "internal_error", @row.last_error_code
    assert_equal 2, adapter.calls.size
    assert_equal Time.utc(2026, 11, 12, 18, 30), Notification.pending.sole.scheduled_for

    run_dispatcher(adapter, config: config, now: RUN_AT + 1.hour)
    assert_equal 2, adapter.calls.size # the failed row is never touched again
  end

  test "a permanent failure fails immediately and queues nothing further" do
    adapter = NotificationsHelper::FakeAdapter.new(Result.failure("user_not_found", retryable: false))
    summary = run_dispatcher(adapter)
    assert_equal 1, summary.failed
    @row.reload
    assert @row.failed?
    assert_equal 1, @row.attempts
    assert_equal "user_not_found", @row.last_error_code
    assert_equal 0, Notification.pending.count
  end

  test "a systemic failure stops the run and releases every row without burning attempts" do
    other = create_user
    other_row = Notifications::Scheduler.schedule_next(other, now: DUE - 6.hours)
    adapter = NotificationsHelper::FakeAdapter.new(Result.failure("invalid_auth", retryable: false, systemic: true))

    summary = run_dispatcher(adapter)

    assert summary.halted
    assert_equal 1, adapter.calls.size
    [ @row, other_row ].each do |row|
      row.reload
      assert row.pending?
      assert_equal 0, row.attempts
    end
    assert_equal 1, [ @row, other_row ].count { |row| row.reload.last_error_code == "invalid_auth" }
  end

  test "an exception from the adapter is a retryable adapter_error and its message is never logged" do
    adapter = Object.new
    def adapter.delivers? = true
    def adapter.deliver_dm(slack_id:, text:) = raise("explode with #{slack_id} #{NotificationsHelper::TOKEN}")
    logs = capture_logs { run_dispatcher(adapter) }
    @row.reload
    assert @row.pending?
    assert_equal "adapter_error", @row.last_error_code
    assert_not_includes logs, @user.slack_id
    assert_not_includes logs, NotificationsHelper::TOKEN
  end

  test "quiet hours defer the send to 07:00 local instead of sending" do
    @row.destroy! # only the Pacific user is under test here
    pacific = create_user(time_zone: "Pacific Time (US & Canada)", coding_time: "23:00") # 07:00 UTC next day
    row = Notifications::Scheduler.schedule_next(pacific, now: Time.utc(2026, 11, 11, 12))
    assert_equal Time.utc(2026, 11, 12, 7, 0), row.scheduled_for
    adapter = NotificationsHelper::FakeAdapter.new

    run_dispatcher(adapter, now: Time.utc(2026, 11, 12, 7, 1)) # 23:01 PST, quiet
    assert_empty adapter.calls
    assert_equal Time.utc(2026, 11, 12, 15, 0), row.reload.due_at # 07:00 PST
    assert row.pending?
    assert_equal 0, row.attempts

    run_dispatcher(adapter, now: Time.utc(2026, 11, 12, 14, 59))
    assert_empty adapter.calls

    run_dispatcher(adapter, now: Time.utc(2026, 11, 12, 15, 0))
    assert_equal [ pacific.slack_id ], adapter.calls.map { |call| call[:slack_id] }
    assert row.reload.sent?
  end

  test "quiet hours bounds come from config" do
    adapter = NotificationsHelper::FakeAdapter.new
    config = CONFIG.with(quiet_start: 18 * 60, quiet_end: 20 * 60) # the reminder lands inside 18:00..20:00
    summary = run_dispatcher(adapter, config: config)
    assert_equal 1, summary.deferred
    assert_empty adapter.calls
    assert_equal Time.utc(2026, 11, 11, 20, 0), @row.reload.due_at
  end

  test "a reminder far past its due time is dropped, not sent late, and the next one is queued" do
    adapter = NotificationsHelper::FakeAdapter.new
    summary = run_dispatcher(adapter, now: DUE + 4.hours) # max_lateness is 3 hours
    assert_equal 1, summary.cancelled
    assert_empty adapter.calls
    assert_equal "stale", @row.reload.last_error_code
    assert @row.cancelled?
    assert_equal Time.utc(2026, 11, 12, 18, 30), Notification.pending.sole.scheduled_for
  end

  test "a changed schedule cancels the old row and queues the new time without sending" do
    @user.update_columns(coding_time: "19:00") # changed without calling the scheduler
    adapter = NotificationsHelper::FakeAdapter.new
    run_dispatcher(adapter)
    assert_empty adapter.calls
    assert @row.reload.cancelled?
    assert_equal "schedule_changed", @row.last_error_code
    assert_equal Time.utc(2026, 11, 11, 19, 0), Notification.pending.sole.scheduled_for
  end

  test "a user who is no longer eligible is cancelled and not rescheduled" do
    @user.update_columns(slack_id: nil)
    adapter = NotificationsHelper::FakeAdapter.new
    run_dispatcher(adapter)
    assert_empty adapter.calls
    assert @row.reload.cancelled?
    assert_equal 0, Notification.pending.count
  end

  test "the limit caps how many rows are handled in a run" do
    others = Array.new(3) { create_user }
    others.each { |user| Notifications::Scheduler.schedule_next(user, now: DUE - 6.hours) }
    adapter = NotificationsHelper::FakeAdapter.new
    summary = run_dispatcher(adapter, limit: 2, config: CONFIG.with(batch_size: 1))
    assert_equal 2, summary.sent
    assert_equal 2, adapter.calls.size
  end

  test "at most one reminder per user per run" do
    adapter = NotificationsHelper::FakeAdapter.new
    # A run a day late (lateness allowed) sends the overdue reminder once; the follow-up it queues is not sent in
    # the same run.
    config = CONFIG.with(max_lateness: 7 * 86_400)
    run_dispatcher(adapter, now: DUE + 1.day + 1.minute, config: config)
    assert_equal 1, adapter.calls.size
    assert_equal 1, Notification.where(user: @user).pending.count
  end

  test "production refuses to run with an adapter that does not really deliver" do
    adapter = NotificationsHelper::FakeAdapter.new(delivers: false)
    summary = with_rails_env("production") { run_dispatcher(adapter) }
    assert summary.halted
    assert_empty adapter.calls
    assert @row.reload.pending?
    # Outside production a non-delivering adapter (null/log) is fine: it exercises the pipeline.
    run_dispatcher(adapter)
    assert @row.reload.sent?
  end

  test "logs carry counters and codes only: never the Slack id, token or message text" do
    other = create_user
    Notifications::Scheduler.schedule_next(other, now: DUE - 6.hours)
    adapter = NotificationsHelper::FakeAdapter.new(Result.failure("user_not_found", retryable: false), Result.success)
    logs = capture_logs { run_dispatcher(adapter) }
    assert_includes logs, "notifications.dispatch"
    [ @user.slack_id, other.slack_id, CONFIG.template("daily_reminder"), NotificationsHelper::TOKEN ].each do |secret|
      assert_not_includes logs, secret
    end
  end
end
