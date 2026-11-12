require "test_helper"
require_relative "../../support/email_helper"

# Notifications::Email::Dispatcher: the Slack dispatcher's rules, for the email channel. FakeAdapter stands in for the
# transport; nothing is ever sent.
class Notifications::EmailDispatcherTest < ActiveSupport::TestCase
  include EmailHelper

  Result = Notifications::Email::Result
  NOON = Time.utc(2026, 11, 11, 12, 0)

  setup do
    @user = create_email_user("disp1")
    @ship = with_feature(:email) { decided_ship(@user, :approved) }
    @row = Notification.find_by!(user_id: @user.id, channel: "email")
    @row.update_columns(due_at: NOON - 1.minute, scheduled_for: NOON - 1.minute)
  end

  def run_dispatcher(adapter, now: NOON, enabled: "true", flag: true)
    with_env("NOTIFICATIONS_ENABLED" => enabled, "APP_URL" => "https://battletown.example.test") do
      flag ? with_feature(:email) { Notifications::Email::Dispatcher.run(now: now, adapter: adapter) } : Notifications::Email::Dispatcher.run(now: now, adapter: adapter)
    end
  end

  test "sends a due email once, marks it sent, and hands the adapter the user and the facts, not a stored body" do
    adapter = FakeAdapter.new
    summary = run_dispatcher(adapter)
    assert_equal 1, summary.sent
    call = adapter.calls.sole
    assert_equal [ @user.id, "ship_approved" ], [ call[:user_id], call[:kind] ]
    assert_equal "Space Farm", call[:values][:project]
    assert_includes call[:values][:link], "/ships/#{@ship.id}"
    @row.reload
    assert @row.sent?
    assert_equal NOON, @row.sent_at

    run_dispatcher(adapter)
    assert_equal 1, adapter.calls.size, "running again sends nothing more"
  end

  test "does nothing while the email flag is off, and leaves the row untouched" do
    adapter = FakeAdapter.new
    summary = run_dispatcher(adapter, flag: false)
    assert_not summary.enabled
    assert_empty adapter.calls
    assert @row.reload.pending?
    assert_equal 0, @row.attempts
  end

  test "does nothing unless NOTIFICATIONS_ENABLED is exactly true" do
    [ nil, "", "false", "1", "TRUE" ].each do |value|
      adapter = FakeAdapter.new
      assert_not run_dispatcher(adapter, enabled: value).enabled, value.inspect
      assert_empty adapter.calls
    end
    assert @row.reload.pending?
  end

  test "a transport that does not deliver records the row as skipped, never sent" do
    summary = run_dispatcher(FakeAdapter.new(delivers: false))
    assert_equal [ 0, 1 ], [ summary.sent, summary.skipped ]
    @row.reload
    assert @row.skipped?
    assert_equal "not_delivered", @row.last_error_code
    assert_nil @row.sent_at
  end

  test "in production without a delivering transport it halts and marks nothing, sent or otherwise" do
    adapter = FakeAdapter.new(delivers: false)
    logs = capture_logs { with_rails_env("production") { @summary = run_dispatcher(adapter) } }
    assert @summary.halted
    assert_empty adapter.calls
    assert @row.reload.pending?
    assert_includes logs, "halted reason=no_delivering_adapter channel=email"
  end

  test "the real adapter does not claim delivery on the test transport, so its rows are skipped" do
    clear_deliveries
    summary = run_dispatcher(Notifications::Email::MailerAdapter.new)
    assert_equal [ 0, 1 ], [ summary.sent, summary.skipped ]
    assert_equal 1, deliveries.size, "the mail was built and went to the :test mailbox only"
    assert @row.reload.skipped?
  end

  test "a person with no address, or one that is not an address, is cancelled as no_address and never sent" do
    [ nil, "nope" ].each do |address|
      @row.update_columns(status: "pending", last_error_code: nil, due_at: NOON - 1.minute)
      @user.update_columns(email: address)
      adapter = FakeAdapter.new
      run_dispatcher(adapter)
      assert_empty adapter.calls, address.inspect
      assert @row.reload.cancelled?
      assert_equal "no_address", @row.last_error_code
    end
  end

  test "a person who switched this kind off for email after it was queued gets nothing" do
    Notifications::Preferences.update!(@user, { "ship_approved" => "0" }, "email")
    adapter = FakeAdapter.new
    run_dispatcher(adapter)
    assert_empty adapter.calls
    assert_equal "opted_out", @row.reload.last_error_code
  end

  test "the global no-email switch cancels queued email" do
    @user.update_columns(email_opted_out_at: Time.current)
    adapter = FakeAdapter.new
    run_dispatcher(adapter)
    assert_empty adapter.calls
    assert_equal "opted_out", @row.reload.last_error_code
  end

  test "a ship that is no longer in the approved state cancels the email as subject_gone" do
    @ship.update_columns(status: "rejected", approved_seconds: nil, rejection_reason: "Changed after review")
    adapter = FakeAdapter.new
    run_dispatcher(adapter)
    assert_empty adapter.calls
    assert_equal "subject_gone", @row.reload.last_error_code
  end

  test "quiet hours defer the email to the end of the window and an old one is dropped as stale" do
    @user.update_columns(time_zone: "UTC")
    adapter = FakeAdapter.new
    night = Time.utc(2026, 11, 11, 23, 0)
    @row.update_columns(due_at: night - 1.minute)
    summary = run_dispatcher(adapter, now: night)
    assert_equal 1, summary.deferred
    assert_empty adapter.calls
    assert_equal Time.utc(2026, 11, 12, 7, 0), @row.reload.due_at

    late = NOON + 3.days
    @row.update_columns(due_at: NOON)
    run_dispatcher(adapter, now: late)
    assert_equal "stale", @row.reload.last_error_code
  end

  test "retryable failures back off and then succeed; permanent ones fail without a retry; systemic ones stop the run" do
    adapter = FakeAdapter.new(Result.failure("smtp_unavailable", retryable: true), Result.success)
    assert_equal 1, run_dispatcher(adapter).retried
    @row.reload
    assert @row.pending?
    assert_equal "smtp_unavailable", @row.last_error_code
    assert_operator @row.due_at, :>, NOON

    @row.update_columns(due_at: NOON - 1.minute)
    assert_equal 1, run_dispatcher(adapter).sent

    other = create_email_user("disp2")
    with_feature(:email) { decided_ship(other, :approved) }
    row = Notification.find_by!(user_id: other.id, channel: "email")
    row.update_columns(due_at: NOON - 1.minute)
    assert_equal 1, run_dispatcher(FakeAdapter.new(Result.failure("smtp_rejected", retryable: false))).failed
    assert row.reload.failed?

    third = create_email_user("disp3")
    with_feature(:email) { decided_ship(third, :approved) }
    third_row = Notification.find_by!(user_id: third.id, channel: "email")
    third_row.update_columns(due_at: NOON - 1.minute)
    assert run_dispatcher(FakeAdapter.new(Result.failure("smtp_auth", retryable: false, systemic: true))).halted
    assert third_row.reload.pending?
  end

  test "an adapter that raises is a retryable failure, logged by class only, with no address in the log" do
    adapter = FakeAdapter.new
    address = @user.email
    adapter.define_singleton_method(:deliver) { |**| raise "SMTP said no to #{address}" }
    logs = capture_logs { run_dispatcher(adapter) }
    assert_includes logs, "adapter_error class=RuntimeError"
    assert_not_includes logs, address
    assert @row.reload.pending?
  end

  test "the Slack dispatcher leaves email rows alone and the email dispatcher leaves Slack rows alone" do
    slack_adapter = NotificationsHelper::FakeAdapter.new
    with_env("NOTIFICATIONS_ENABLED" => "true") { Notifications::Dispatcher.run(now: NOON, adapter: slack_adapter) }
    assert @row.reload.pending?, "the Slack dispatcher skipped the email row"

    slack_row = Notification.find_by!(user_id: @user.id, channel: "slack_dm", kind: "ship_approved")
    slack_row.update_columns(due_at: NOON - 1.minute)
    adapter = FakeAdapter.new
    run_dispatcher(adapter)
    assert slack_row.reload.pending?
    assert_equal 1, adapter.calls.size
  end

  # --- the weekly cap on nudges ---

  test "a welcome-back nudge is cancelled when the person already got the weekly maximum, ship decisions never count or are capped" do
    cap = Notifications::Email::Config.current.max_per_week
    cap.times { |i| email_row(@user, kind: "returning_nudge", status: "sent", due_at: NOON - (i + 1).hours).update_columns(sent_at: NOON - (i + 1).hours) }
    nudge = email_row(@user, kind: "returning_nudge", subject_id: 20_000, due_at: NOON - 1.minute)
    adapter = FakeAdapter.new
    run_dispatcher(adapter)

    assert_equal "weekly_cap", nudge.reload.last_error_code
    assert nudge.cancelled?
    assert_equal [ "ship_approved" ], adapter.calls.map { |call| call[:kind] }, "the decision email is not capped"
  end

  test "a nudge goes out when the earlier ones are older than a week" do
    email_row(@user, kind: "returning_nudge", status: "sent").update_columns(sent_at: NOON - 8.days, due_at: NOON - 8.days)
    nudge = email_row(@user, kind: "returning_nudge", subject_id: 20_000, due_at: NOON - 1.minute)
    @row.update_columns(status: "cancelled")
    adapter = FakeAdapter.new
    run_dispatcher(adapter)
    assert nudge.reload.sent?
  end
end
