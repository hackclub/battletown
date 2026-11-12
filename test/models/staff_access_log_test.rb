require "test_helper"

class StaffAccessLogTest < ActiveSupport::TestCase
  setup do
    @admin = users(:onboarded)
    @answer = NpsResponse.create!(user: users(:new_user), score: 5, comment: "secret words", answered_at: Time.current, prompt_window_date: Date.new(2026, 11, 12))
  end

  test "records who looked at which row and nothing else" do
    log = StaffAccessLog.record!(actor: @admin, action: "nps_comment_author_viewed", subject: @answer)
    assert_equal [ @admin.id, "nps_comment_author_viewed", "NpsResponse", @answer.id ], [ log.actor_id, log.action, log.subject_type, log.subject_id ]
    assert_equal %w[action actor_id created_at id subject_id subject_type], StaffAccessLog.column_names.sort
    assert_not_includes log.attributes.values.map(&:to_s).join(" "), "secret words"
  end

  test "an unknown action is refused and a saved row cannot be changed" do
    assert_raises(ActiveRecord::RecordInvalid) { StaffAccessLog.record!(actor: @admin, action: "something_else", subject: @answer) }
    log = StaffAccessLog.record!(actor: @admin, action: "nps_comment_author_viewed", subject: @answer)
    assert_raises(ActiveRecord::ReadOnlyRecord) { log.update!(action: "nps_comment_author_viewed") }
  end

  test "deleting the staff member keeps the log row and forgets who they were" do
    log = StaffAccessLog.record!(actor: @admin, action: "nps_comment_author_viewed", subject: @answer)
    User.where(id: @admin.id).delete_all
    assert_nil log.reload.actor_id
  end
end
