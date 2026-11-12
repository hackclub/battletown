require "test_helper"

class HourEntryTest < ActiveSupport::TestCase
  setup { @user = users(:onboarded) }

  def build(**attrs)
    HourEntry.new({ user: @user, local_date: Date.new(2026, 11, 10), seconds: 900, source: "manual", note: "Test",
                    idempotency_key: "k-#{SecureRandom.hex(4)}" }.merge(attrs))
  end

  # A failed statement aborts the surrounding test transaction, so each attempt runs in a savepoint.
  def assert_db_rejects(**attrs)
    columns = { user_id: @user.id, local_date: Date.new(2026, 11, 10), seconds: 900, source: "manual", note: "Test",
                idempotency_key: "k-#{SecureRandom.hex(4)}" }.merge(attrs)
    assert_raises(ActiveRecord::StatementInvalid, "#{attrs.inspect} should be rejected by the database") do
      HourEntry.transaction(requires_new: true) { HourEntry.insert_all!([ columns ]) }
    end
  end

  test "a valid manual entry saves" do
    assert build.save
  end

  test "model validations" do
    assert_not build(source: "other").valid?
    assert_not build(seconds: 0).valid?
    assert_not build(seconds: 86_401).valid?
    assert_not build(seconds: -60).valid?, "negative only for adjustments"
    assert build(seconds: -60, source: "adjustment").valid?
    assert_not build(seconds: -86_401, source: "adjustment").valid?
    assert_not build(seconds: 1.5).valid?
    assert_not build(note: nil).valid?, "manual needs a note"
    assert_not build(source: "adjustment", note: "").valid?
    assert build(source: "hackatime", note: nil).valid?
    assert_not build(note: "x" * 201).valid?
    assert_not build(idempotency_key: "").valid?
    assert_not build(idempotency_key: "k" * 121).valid?
    assert_not build(hackatime_project: "p" * 121).valid?
    assert_not build(hackatime_project: "").valid?
    assert_not build(created_by: "Some Person").valid?
    assert build(created_by: "rake:credit").valid?
    assert_not build(local_date: nil).valid?
  end

  test "the database enforces the same rules" do
    assert_db_rejects(source: "other")
    assert_db_rejects(seconds: 0)
    assert_db_rejects(seconds: 86_401)
    assert_db_rejects(seconds: -86_401, source: "adjustment")
    assert_db_rejects(seconds: -60)
    assert_db_rejects(note: nil)
    assert_db_rejects(source: "adjustment", note: nil, seconds: -60)
    assert_db_rejects(note: "x" * 201)
    assert_db_rejects(idempotency_key: "")
    assert_db_rejects(idempotency_key: "k" * 121)
    assert_db_rejects(hackatime_project: "p" * 121)
    assert_db_rejects(hackatime_project: "")
    assert_db_rejects(created_by: "Some Person")
    assert_db_rejects(local_date: nil)
    HourEntry.insert_all!([ { user_id: @user.id, local_date: Date.new(2026, 11, 10), seconds: -86_400, source: "adjustment", note: "ok",
                              idempotency_key: "edge", hackatime_project: "p" * 120 } ])
  end

  test "an idempotency key is unique per user, not across users" do
    build(idempotency_key: "same").save!
    assert_raises(ActiveRecord::RecordNotUnique) { HourEntry.transaction(requires_new: true) { build(idempotency_key: "same").save!(validate: false) } }
    assert build(user: users(:new_user), idempotency_key: "same").save
  end

  test "a persisted entry is immutable" do
    entry = build.tap(&:save!)
    assert_predicate entry, :readonly?

    assert_raises(ActiveRecord::ReadOnlyRecord) { entry.update!(seconds: 1_800) }
    assert_raises(ActiveRecord::ReadOnlyRecord) { entry.destroy }
    assert_raises(ActiveRecord::ReadOnlyRecord) { HourEntry.find(entry.id).update!(note: "changed") }
    assert_equal 900, entry.reload.seconds
    assert_not_predicate build, :readonly?
  end

  test "deleting the user deletes the entries (database cascade)" do
    user = User.create!(hca_uid: "ident!cascade")
    HourEntry.create!(user: user, local_date: Date.new(2026, 11, 10), seconds: 600, source: "manual", note: "a", idempotency_key: "a")
    HourEntry.create!(user: user, local_date: Date.new(2026, 11, 10), seconds: -60, source: "adjustment", note: "b", idempotency_key: "b")
    keep = build.tap(&:save!)

    assert_difference "HourEntry.count", -2 do
      user.destroy!
    end
    assert HourEntry.exists?(keep.id)
    assert_not HourEntry.exists?(user_id: user.id)
  end

  test "deleting a user through the privacy deleter reports the hour entries" do
    build.save!
    subject = Privacy::TokenVerifier::Subject.new(emails: [], slack_id: nil, identity_id: @user.hca_uid)

    result = Privacy::Deleter.new(subject).call(dry_run: false)

    assert_equal 1, result.deleted["hour_entries"]
    assert_not HourEntry.exists?(user_id: @user.id)
  end
end
