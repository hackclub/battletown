require "test_helper"
require_relative "../../support/email_helper"

# Which events queue an email row, and when they must not. The real subscribers and the real ship services run; nothing
# is sent.
class Notifications::EmailTriggersTest < ActiveSupport::TestCase
  include EmailHelper

  setup { @user = create_email_user("trig1") }

  def email_rows(kind = nil)
    scope = Notification.where(user_id: @user.id, channel: "email")
    kind ? scope.where(kind: kind) : scope
  end

  def slack_nudge(user = @user, key: "returning_nudge:#{user.id}:1")
    Notification.create!(user: user, kind: "returning_nudge", channel: "slack_dm", status: "pending", subject_id: 20_000,
                         scheduled_for: Time.current, due_at: Time.current, idempotency_key: key)
  end

  # --- ship decisions ---

  test "with the flag on, an approval queues one email row next to the Slack row, holding no address and no text" do
    with_feature(:email) { decided_ship(@user, :approved) }

    assert_equal 1, Notification.where(user_id: @user.id, channel: "slack_dm", kind: "ship_approved").count
    row = email_rows("ship_approved").sole
    assert row.pending?
    assert_equal "email:ship_decision:#{row.subject_id}", row.idempotency_key
    assert_not_includes row.attributes.values.map(&:to_s).join(" "), @user.email
    assert_equal %w[id user_id kind channel status scheduled_for due_at attempts last_error_code sent_at idempotency_key created_at updated_at subject_id].sort,
                 row.attributes.keys.sort, "no column that could hold an address or message text"
  end

  test "a rejection queues a ship_rejected email, and a repeated event never a second one" do
    ship = with_feature(:email) { decided_ship(@user, :rejected) }
    with_feature(:email) { 3.times { ActiveSupport::Notifications.instrument("ship_rejected.battletown", ship_id: ship.id) } }

    assert_equal [ "ship_rejected" ], email_rows.pluck(:kind)
  end

  test "with the flag off nothing about email is queued" do
    without_feature(:email) do
      decided_ship(@user, :approved)
      slack_nudge
    end
    assert_empty email_rows
    assert_equal 1, Notification.where(user_id: @user.id, kind: "ship_approved", channel: "slack_dm").count, "the Slack side is untouched"
  end

  test "email is additional: no Slack id still gets the email, and each channel is switched off on its own" do
    @user.update_columns(slack_id: nil)
    with_feature(:email) { decided_ship(@user, :approved) }
    assert_equal 1, email_rows.count
    assert_equal 0, Notification.where(user_id: @user.id, channel: "slack_dm").count

    other = create_email_user("trig2")
    Notifications::Preferences.update!(other, { "ship_approved" => "0" }, "email")
    with_feature(:email) { decided_ship(other, :approved) }
    assert_equal 0, Notification.where(user_id: other.id, channel: "email").count
    assert_equal 1, Notification.where(user_id: other.id, channel: "slack_dm", kind: "ship_approved").count

    third = create_email_user("trig3")
    Notifications::Preferences.update!(third, { "ship_approved" => "0" })
    with_feature(:email) { decided_ship(third, :approved) }
    assert_equal 1, Notification.where(user_id: third.id, channel: "email").count
    assert_equal 0, Notification.where(user_id: third.id, channel: "slack_dm", kind: "ship_approved").count
  end

  test "no address, an invalid address, the per-kind switch or the global switch each mean no row" do
    [ nil, "", "not-an-address", "a b@example.test", "a@example.test, b@example.test" ].each_with_index do |address, i|
      user = create_email_user("bad#{i}")
      user.update_columns(email: address) # past the model validation, like a legacy row
      with_feature(:email) { decided_ship(user, :approved) }
      assert_equal 0, Notification.where(user_id: user.id, channel: "email").count, address.inspect
    end

    opted_out = create_email_user("out1", email_opted_out_at: Time.current)
    with_feature(:email) { decided_ship(opted_out, :approved) }
    assert_equal 0, Notification.where(user_id: opted_out.id, channel: "email").count
  end

  test "a user who has not finished onboarding gets no email row" do
    user = create_email_user("new1", onboarded_at: nil, onboarding_step: 1)
    assert_nil Notifications::Outbox.enqueue(user: user, kind: "ship_approved", subject_id: 1, key: "email:x:1", channel: "email")
  end

  # --- welcome back (the returning_nudge Slack row) ---

  test "a returning_nudge Slack row queues exactly one welcome-back email, keyed on that row" do
    row = with_feature(:email) { slack_nudge }
    email = email_rows("returning_nudge").sole
    assert_equal "email:#{row.idempotency_key}", email.idempotency_key
    assert_equal row.subject_id, email.subject_id

    with_feature(:email) { Notifications::Email::Triggers.slack_row_created(row) }
    assert_equal 1, email_rows("returning_nudge").count, "the same Slack row never queues a second email"
  end

  test "the welcome-back email follows only returning_nudge Slack rows, and only with the flag on" do
    without_feature(:email) { slack_nudge }
    assert_empty email_rows

    with_feature(:email) do
      Notification.create!(user: @user, kind: "ship_mvp", channel: "slack_dm", status: "pending", subject_id: 1, scheduled_for: Time.current,
                           due_at: Time.current, idempotency_key: "ship_mvp:#{@user.id}:1")
    end
    assert_empty email_rows
  end

  test "the welcome-back email respects the per-kind, global and address rules" do
    off = create_email_user("wb1")
    Notifications::Preferences.update!(off, { "returning_nudge" => "0" }, "email")
    none = create_email_user("wb2", email: nil)
    out = create_email_user("wb3", email_opted_out_at: Time.current)
    with_feature(:email) { [ off, none, out ].each_with_index { |user, i| slack_nudge(user, key: "returning_nudge:#{user.id}:#{i}") } }

    assert_equal 0, Notification.where(user_id: [ off.id, none.id, out.id ], channel: "email").count
  end

  test "a trigger failure is swallowed and logged by class only, never breaking the caller" do
    logs = capture_logs do
      with_feature(:email) do
        original = Notifications::Outbox.method(:enqueue)
        address = @user.email
        Notifications::Outbox.define_singleton_method(:enqueue) { |**| raise "boom for #{address}" }
        begin
          slack_nudge
        ensure
          Notifications::Outbox.define_singleton_method(:enqueue, original)
        end
      end
    end
    assert_includes logs, "notifications.email.trigger error=RuntimeError kind=returning_nudge"
    assert_not_includes logs, @user.email
    assert_equal 1, Notification.where(user_id: @user.id, kind: "returning_nudge", channel: "slack_dm").count
  end

  test "the real returning scan queues the Slack nudge and, with the email flag on, exactly one welcome-back email, which then sends" do
    user = create_email_user("scan1", created_at: Time.utc(2026, 11, 1, 9))
    user.update_columns(signed_up_on: Date.new(2026, 11, 1))
    code(user, Date.new(2026, 11, 1), 900)
    now = Time.utc(2026, 11, 9, 12)

    with_feature(:returning) { with_feature(:email) { 2.times { Notifications::ReturningNudges.scan(now: now) } } }
    slack = Notification.find_by!(user_id: user.id, kind: "returning_nudge", channel: "slack_dm")
    email = Notification.find_by!(user_id: user.id, kind: "returning_nudge", channel: "email")
    assert_equal slack.subject_id, email.subject_id
    assert_equal 1, Notification.where(user_id: user.id, kind: "returning_nudge", channel: "email").count

    adapter = EmailHelper::FakeAdapter.new
    with_env("NOTIFICATIONS_ENABLED" => "true") do
      with_feature(:returning) { with_feature(:email) { Notifications::Email::Dispatcher.run(now: now + 1.minute, adapter: adapter) } }
    end
    assert_equal [ "returning_nudge" ], adapter.calls.map { |call| call[:kind] }, email.reload.attributes.slice("status", "last_error_code").inspect
    assert email.reload.sent?
  end

  test "with the email flag off the real returning scan queues only the Slack nudge" do
    user = create_email_user("scan2", created_at: Time.utc(2026, 11, 1, 9))
    user.update_columns(signed_up_on: Date.new(2026, 11, 1))
    code(user, Date.new(2026, 11, 1), 900)
    with_feature(:returning) { Notifications::ReturningNudges.scan(now: Time.utc(2026, 11, 9, 12)) }
    assert_equal 1, Notification.where(user_id: user.id, kind: "returning_nudge", channel: "slack_dm").count
    assert_equal 0, Notification.where(user_id: user.id, channel: "email").count
  end
end
