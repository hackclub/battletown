require "test_helper"
require_relative "../support/notifications_helper"

# The model validations are the first line of defence; the database constraints are the backstop. The constraint
# tests bypass validations (update_column / raw inserts) to prove the database rejects bad data on its own.
class NotificationTest < ActiveSupport::TestCase
  include NotificationsHelper

  setup do
    @user = create_user
    @due = Time.utc(2026, 11, 12, 18, 30)
  end

  def build(**attrs)
    Notification.new({ user: @user, kind: "daily_reminder", channel: "slack_dm", status: "pending", scheduled_for: @due,
                       due_at: @due, idempotency_key: Notification.idempotency_key_for(kind: "daily_reminder", user_id: @user.id, scheduled_for: @due) }.merge(attrs))
  end

  # A failed statement aborts the surrounding test transaction, so each attempt runs in a savepoint.
  def assert_db_rejects(error_class = ActiveRecord::CheckViolation, &block)
    assert_raises(error_class) { Notification.transaction(requires_new: true, &block) }
  end

  test "a well-formed row is valid and has sensible defaults" do
    row = build
    assert row.valid?, row.errors.full_messages.to_sentence
    row.save!
    assert_equal 0, row.attempts
    assert_nil row.last_error_code
    assert_nil row.sent_at
    assert row.pending?
    assert_equal "daily_reminder:#{@user.id}:2026-11-12T18:30:00Z", row.idempotency_key
  end

  test "validations mirror the database constraints" do
    assert_not build(kind: "spam").valid?
    assert_not build(channel: "sms").valid?
    assert_not build(status: "queued").valid?
    assert_not build(attempts: -1).valid?
    assert_not build(attempts: 11).valid?
    assert build(attempts: 10).valid?
    assert_not build(last_error_code: "Rate Limited!").valid?
    assert_not build(last_error_code: "x" * 41).valid?
    assert build(last_error_code: "ratelimited").valid?
    assert_not build(scheduled_for: nil).valid?
    assert_not build(due_at: nil).valid?
    assert_not build(idempotency_key: nil).valid?
    assert_not build(user: nil).valid?
  end

  test "the idempotency key must be unique" do
    build.save!
    duplicate = build(status: "cancelled")
    assert_not duplicate.valid?
    assert_includes duplicate.errors.attribute_names, :idempotency_key
  end

  test "database rejects an unknown kind, channel or status" do
    row = build.tap(&:save!)
    assert_db_rejects { row.update_column(:kind, "spam") }
    assert_db_rejects { row.update_column(:channel, "sms") }
    assert_db_rejects { row.update_column(:status, "queued") }
    %w[pending sent failed cancelled].each { |status| row.update_column(:status, status) }
  end

  test "database limits attempts to 0..10" do
    row = build.tap(&:save!)
    assert_db_rejects { row.update_column(:attempts, -1) }
    assert_db_rejects { row.update_column(:attempts, 11) }
    [ 0, 10 ].each { |attempts| row.update_column(:attempts, attempts) }
  end

  test "database only accepts short snake case error codes (no free text can be stored)" do
    row = build.tap(&:save!)
    [ "Rate limited", "a b", "token=xoxb-1", "UPPER" ].each do |bad|
      assert_db_rejects { row.update_column(:last_error_code, bad) }
    end
    assert_db_rejects(ActiveRecord::ValueTooLong) { row.update_column(:last_error_code, "x" * 41) }
    [ nil, "ratelimited", "http_error", "a" * 40 ].each { |ok| row.update_column(:last_error_code, ok) }
  end

  test "database rejects a null user, a missing user, and a duplicate idempotency key" do
    row = build.tap(&:save!)
    assert_db_rejects(ActiveRecord::NotNullViolation) { row.update_column(:user_id, nil) }
    assert_db_rejects(ActiveRecord::InvalidForeignKey) { row.update_column(:user_id, 0) }
    other = build(idempotency_key: "daily_reminder:other:key", status: "cancelled").tap(&:save!)
    assert_db_rejects(ActiveRecord::RecordNotUnique) { other.update_column(:idempotency_key, row.idempotency_key) }
  end

  test "database allows only one pending notification per user and kind" do
    build.save!
    second = build(scheduled_for: @due + 1.day, due_at: @due + 1.day, idempotency_key: "daily_reminder:second")
    assert_db_rejects(ActiveRecord::RecordNotUnique) { second.save!(validate: false) }
    second.status = "cancelled"
    second.save! # finished rows do not count
  end

  test "deleting the user deletes their notifications at the database level (cascade)" do
    build.save!
    other_user = create_user
    build(user: other_user, idempotency_key: "daily_reminder:other").save!
    assert_difference -> { Notification.count }, -1 do
      User.where(id: @user.id).delete_all # no callbacks: only the foreign key can remove the row
    end
    assert_equal [ other_user.id ], Notification.pluck(:user_id).uniq & [ other_user.id, @user.id ]
  end

  test "destroying the user through the model also removes them" do
    build.save!
    assert_difference -> { Notification.count }, -1 do
      @user.destroy!
    end
  end

  test "the due scope returns pending rows at or before now" do
    build.save!
    assert_empty Notification.due(@due - 1)
    assert_equal 1, Notification.due(@due).count
    Notification.update_all(status: "sent")
    assert_empty Notification.due(@due + 1.day)
  end

  test "pending event rows are indexed by subject so a ship submit cancels its reminders without a scan" do
    index = ActiveRecord::Base.connection.indexes(:notifications).find { |i| i.name == "index_notifications_on_pending_subject_id" }
    assert index, "missing the partial subject index"
    assert_equal [ "subject_id" ], index.columns
    assert_match(/status\)::text = 'pending'/, index.where)
  end
end
