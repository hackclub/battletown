require "test_helper"

# The model validations are the first line of defence. These tests bypass them (update_column / raw SQL)
# to prove the database check constraints reject bad data on their own.
class UserDbConstraintsTest < ActiveSupport::TestCase
  setup { @user = users(:onboarded) }

  # A failed statement aborts the surrounding test transaction, so each attempt runs in a savepoint.
  def assert_rejected(column, value)
    error = assert_raises(ActiveRecord::StatementInvalid, "#{column}=#{value.inspect} should be rejected") do
      User.transaction(requires_new: true) { @user.update_column(column, value) }
    end
    assert_kind_of ActiveRecord::CheckViolation, error
  end

  def assert_accepted(column, values)
    values.each { |value| @user.update_column(column, value) }
  end

  test "project_kind must be one of the allowed kinds or NULL" do
    assert_rejected :project_kind, "spaceship"
    assert_accepted :project_kind, [ nil, *User::PROJECT_KINDS ]
  end

  test "project_idea is limited to 500 characters" do
    assert_rejected :project_idea, "x" * 501
    assert_accepted :project_idea, [ "x" * 500, nil, "" ]
  end

  test "coding_time must be HH:MM or NULL" do
    [ "25:00", "7:30", "12:60", "12:30\nfoo", "noon", "" ].each { |bad| assert_rejected :coding_time, bad }
    assert_accepted :coding_time, [ "00:00", "23:59", nil ]
  end

  test "onboarding_step must be between 0 and 4" do
    [ -1, 5 ].each { |bad| assert_rejected :onboarding_step, bad }
    assert_accepted :onboarding_step, [ 0, 4 ]
  end

  test "coding_days must be between 0 and 127" do
    [ -1, 128 ].each { |bad| assert_rejected :coding_days, bad }
    assert_accepted :coding_days, [ 0, 127 ]
  end

  test "verification_status must be a known status" do
    assert_rejected :verification_status, "totally_verified"
    assert_accepted :verification_status, User.verification_statuses.values
  end

  test "raw SQL cannot bypass the constraints either" do
    assert_raises(ActiveRecord::CheckViolation) do
      User.transaction(requires_new: true) do
        User.connection.execute("UPDATE users SET onboarding_step = 99 WHERE id = #{@user.id}")
      end
    end
  end

  test "prize_key is not constrained in the database because prizes are placeholder data" do
    assert_accepted :prize_key, [ "not-a-current-prize" ]
    assert_equal "not-a-current-prize", @user.reload.prize_key
  end

  test "fixtures satisfy every constraint" do
    assert_equal 2, User.where(id: [ users(:new_user).id, users(:onboarded).id ]).count
  end
end
