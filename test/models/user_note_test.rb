require "test_helper"

class UserNoteTest < ActiveSupport::TestCase
  setup do
    @staff = users(:onboarded)
    @user = users(:new_user)
  end

  def add(body) = AdminUsers::AddNote.call(staff: @staff, user: @user, body: body)

  test "adds a note and one audit event that does not carry the text" do
    note = add("Asked about their missing hours.")
    assert_equal [ @user.id, @staff.id, "Asked about their missing hours." ], [ note.user_id, note.author_id, note.body ]
    assert_in_delta Time.current, note.created_at, 5.seconds
    event = AdminAuditEvent.sole
    assert_equal [ "user_note_added", "User", @user.id, { "note_id" => note.id } ], [ event.action, event.subject_type, event.subject_id, event.metadata ]
    assert_not_includes event.attributes.values.join(" "), "missing hours"
  end

  test "the text is tidied and limited to 500 characters" do
    assert_equal "a b c", add("  a\t b\u0000 c  ").body
    assert_equal 500, add("x" * 500).body.length
    assert_raises(AdminUsers::AddNote::Invalid) { add("x" * 501) }
    error = assert_raises(AdminUsers::AddNote::Invalid) { add("   ") }
    assert_equal "The note can't be blank", error.message
    assert_raises(AdminUsers::AddNote::Invalid) { add(nil) }
    assert_equal 2, UserNote.count
    assert_equal 2, AdminAuditEvent.count
  end

  test "the database also refuses an empty or oversized body" do
    now = Time.current.utc.iso8601
    assert_raises(ActiveRecord::StatementInvalid) do
      UserNote.connection.execute("INSERT INTO user_notes (user_id, body, created_at) VALUES (#{@user.id}, '   ', '#{now}')")
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      UserNote.connection.execute("INSERT INTO user_notes (user_id, body, created_at) VALUES (#{@user.id}, '#{'x' * 501}', '#{now}')")
    end
  end

  test "notes are append-only" do
    note = add("Keep this.")
    assert_raises(ActiveRecord::ReadOnlyRecord) { note.update!(body: "Changed") }
    assert_raises(ActiveRecord::ReadOnlyRecord) { note.update_columns(body: "Changed") }
    assert_raises(ActiveRecord::ReadOnlyRecord) { note.destroy }
    assert_raises(ActiveRecord::ReadOnlyRecord) { note.delete }
    assert_equal "Keep this.", note.reload.body
  end

  test "the note goes with the person, and the author is forgotten when the author is deleted" do
    note = add("About the person.")
    User.where(id: @staff.id).delete_all
    assert_nil note.reload.author_id
    assert_equal "About the person.", note.body
    User.where(id: @user.id).delete_all
    assert_not UserNote.exists?(note.id)
  end

  test "an audit failure rolls the note back" do
    stub_method(AdminAudit, :record!, ->(**) { raise ActiveRecord::StatementInvalid, "boom" }) do
      assert_raises(ActiveRecord::StatementInvalid) { add("Will not stay.") }
    end
    assert_equal 0, UserNote.count
  end
end
