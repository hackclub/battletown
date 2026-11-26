require "test_helper"

class ApplicationCable::ConnectionTest < ActionCable::Connection::TestCase
  tests ApplicationCable::Connection

  test "a signed-in, onboarded player connects, and only their id is kept" do
    user = users(:onboarded)
    connect session: { user_id: user.id }
    assert_equal user.id, connection.current_user_id
  end

  test "nobody signed in is rejected" do
    assert_reject_connection { connect }
  end

  test "a session for a user that does not exist is rejected" do
    assert_reject_connection { connect session: { user_id: 0 } }
  end

  test "a signed-in player who has not finished onboarding is rejected" do
    user = users(:onboarded)
    user.update_columns(onboarded_at: nil)
    assert_reject_connection { connect session: { user_id: user.id } }
  end
end
