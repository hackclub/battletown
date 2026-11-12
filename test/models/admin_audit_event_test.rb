require "test_helper"

class AdminAuditEventTest < ActiveSupport::TestCase
  setup do
    @staff = users(:onboarded)
    @subject = users(:new_user)
  end

  def record(**overrides)
    AdminAudit.record!(**{ actor: @staff, action: "user_viewed", subject: @subject }.merge(overrides))
  end

  test "records who did what to which row, and nothing else" do
    event = record(metadata: { amount: 5, reason: "Fixing a double count" })
    assert_equal [ @staff.id, "user_viewed", "User", @subject.id ], [ event.actor_id, event.action, event.subject_type, event.subject_id ]
    assert_equal({ "amount" => 5, "reason" => "Fixing a double count" }, event.reload.metadata)
    assert_equal %w[action actor_id created_at id metadata subject_id subject_type], AdminAuditEvent.column_names.sort
    assert_in_delta Time.current, event.created_at, 5.seconds
  end

  test "a subject can be a record or a type and id pair" do
    assert_equal [ "User", @subject.id ], record.then { |event| [ event.subject_type, event.subject_id ] }
    event = record(subject: [ "ShopItem", "42" ])
    assert_equal [ "ShopItem", 42 ], [ event.subject_type, event.subject_id ]
    assert_raises(ArgumentError) { record(subject: User.new) }
    assert_raises(ArgumentError) { record(subject: "a string") }
  end

  test "only allowlisted actions are accepted" do
    assert_includes AdminAudit::ACTIONS, "nps_comment_author_viewed"
    assert_equal AdminAudit::ACTIONS.uniq, AdminAudit::ACTIONS
    assert_raises(ActiveRecord::RecordInvalid) { record(action: "something_else") }
    assert_raises(ActiveRecord::RecordInvalid) { record(action: "") }
    assert_raises(ActiveRecord::RecordInvalid) { record(action: nil) }
    assert_equal 0, AdminAuditEvent.count
  end

  test "the actor must be a saved user" do
    assert_raises(ArgumentError) { record(actor: nil) }
    assert_raises(ArgumentError) { record(actor: User.new) }
    assert_raises(ArgumentError) { record(actor: "staff") }
  end

  test "a saved row cannot be changed or deleted" do
    event = record
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.update!(action: "hours_adjusted") }
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.update_columns(action: "hours_adjusted") }
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.destroy }
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.delete }
    assert_raises(ActiveRecord::ReadOnlyRecord) { AdminAuditEvent.find(event.id).update!(metadata: {}) }
    assert_equal "user_viewed", event.reload.action
  end

  test "deleting the staff member keeps the row and forgets who they were" do
    event = record
    User.where(id: @staff.id).delete_all
    assert_nil event.reload.actor_id
    assert_equal "user_viewed", event.action
  end

  test "deleting the person it was about does not touch the row (the subject is only a type and an id)" do
    event = record
    User.where(id: @subject.id).delete_all
    assert_equal @subject.id, event.reload.subject_id
  end

  test "metadata must be a flat hash of small values" do
    assert_raises(ActiveRecord::RecordInvalid) { record(metadata: { nested: { a: 1 } }) }
    assert_raises(ActiveRecord::RecordInvalid) { record(metadata: { list: [ 1, 2 ] }) }
    assert_raises(ActiveRecord::RecordInvalid) { record(metadata: { amount: 1.5 }) }
    assert_raises(ActiveRecord::RecordInvalid) { record(metadata: { reason: "x" * 201 }) }
    assert_raises(ActiveRecord::RecordInvalid) { record(metadata: (1..13).to_h { |i| [ "k#{i}", i ] }) }
    assert_raises(ActiveRecord::RecordInvalid) { record(metadata: { "Bad Key" => 1 }) }
    assert_raises(ArgumentError) { record(metadata: "text") }
    assert_nothing_raised { record(metadata: { ok: true, none: nil, count: 3, when: Date.new(2026, 11, 10), reason: "x" * 200 }) }
  end

  test "metadata refuses keys and values that look personal" do
    %i[email display_name slack_id hca_uid name phone address ip token comment message body birthdate].each do |key|
      assert_raises(ActiveRecord::RecordInvalid, "#{key} must be refused") { record(metadata: { key => "x" }) }
    end
    assert_raises(ActiveRecord::RecordInvalid) { record(metadata: { reason: "ask kid@example.test" }) }
    assert_raises(ActiveRecord::RecordInvalid) { record(metadata: { reason: "call 555 123 4567 please" }) }
    assert_raises(ActiveRecord::RecordInvalid) { record(metadata: { ship_user_slack_id: 1 }) }
    assert_nothing_raised { record(metadata: { transaction_id: 7, entry_id: 8, ship_status: "approved", user_id: 3 }) }
  end

  test "the database also insists metadata is an object" do
    assert_raises(ActiveRecord::StatementInvalid) do
      AdminAuditEvent.connection.execute("INSERT INTO admin_audit_events (action, subject_type, subject_id, created_at, metadata) VALUES ('user_viewed', 'User', 1, now(), '[1]')")
    end
  end

  test "record_once! writes one row per actor, action and subject inside the window" do
    first = AdminAudit.record_once!(actor: @staff, action: "user_viewed", subject: @subject, within: 10.minutes)
    assert_kind_of AdminAuditEvent, first
    assert_nil AdminAudit.record_once!(actor: @staff, action: "user_viewed", subject: @subject, within: 10.minutes)
    assert_kind_of AdminAuditEvent, AdminAudit.record_once!(actor: users(:new_user), action: "user_viewed", subject: @subject, within: 10.minutes)
    assert_kind_of AdminAuditEvent, AdminAudit.record_once!(actor: @staff, action: "user_viewed", subject: @staff, within: 10.minutes)

    travel 11.minutes do
      assert_kind_of AdminAuditEvent, AdminAudit.record_once!(actor: @staff, action: "user_viewed", subject: @subject, within: 10.minutes)
    end
    assert_equal 4, AdminAuditEvent.count
  end
end
