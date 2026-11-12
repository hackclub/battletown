require "test_helper"

class NpsResponseTest < ActiveSupport::TestCase
  setup { @user = users(:onboarded) }

  def build(**attrs) = NpsResponse.new({ user: @user, score: 8, answered_at: Time.current, prompt_window_date: Date.new(2026, 11, 12) }.merge(attrs))

  test "a score from 0 to 10 and no comment is valid" do
    (0..10).each { |score| assert build(score: score).valid?, score }
  end

  test "scores outside 0 to 10, fractions and blanks are refused" do
    [ -1, 11, 100, nil ].each { |score| assert_not build(score: score).valid?, score.inspect }
    assert_not build(score: 7.5).valid?
  end

  test "the database refuses a score outside 0 to 10 and a comment over 300 characters even if the model is skipped" do
    row = build(score: 11)
    assert_raises(ActiveRecord::StatementInvalid) { row.save!(validate: false) }
    assert_raises(ActiveRecord::StatementInvalid) { build(comment: "x" * 301).save!(validate: false) }
    assert build(comment: "x" * 300).save, "exactly 300 is fine"
  end

  test "the model limits the comment to 300 characters and plain text" do
    assert_not build(comment: "x" * 301).valid?
    assert_not build(comment: "line one\nline two").valid?
    assert build(comment: "<b>bold</b> & <script>alert(1)</script>").valid?, "markup is just text here: it is escaped where shown"
  end

  test "one answer per person per prompt window, but another window or another person is fine" do
    build.save!
    assert_not build(score: 3).valid?
    assert_raises(ActiveRecord::RecordNotUnique) { build(score: 3).save!(validate: false) }
    assert build(prompt_window_date: Date.new(2026, 11, 14)).valid?
    assert build(user: users(:new_user)).valid?
  end

  test "clean_comment turns typed text into the stored comment" do
    assert_nil NpsResponse.clean_comment(nil)
    assert_nil NpsResponse.clean_comment("  \n\t ")
    assert_equal "a b c", NpsResponse.clean_comment("  a\n\nb\t c \u0000")
    assert_equal "<i>hi</i>", NpsResponse.clean_comment("<i>hi</i>")
  end

  test "deleting the user deletes their answers" do
    build.save!
    assert_difference -> { NpsResponse.count }, -1 do
      User.where(id: @user.id).delete_all
    end
  end
end
