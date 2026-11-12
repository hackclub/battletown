require "test_helper"
require_relative "../support/hackatime_helper"

class HackatimeConnectionTest < ActiveSupport::TestCase
  include HackatimeHelper

  test "tokens are encrypted at rest: the raw column is not the plaintext, and it reads back" do
    connection = connect_hackatime(users(:onboarded), refresh_token: SECRET_REFRESH)

    raw = ActiveRecord::Base.connection.select_one("SELECT access_token, refresh_token FROM hackatime_connections WHERE id = #{connection.id}")
    assert_not_equal SECRET_TOKEN, raw["access_token"]
    assert_not_includes raw["access_token"], SECRET_TOKEN
    assert_not_equal SECRET_REFRESH, raw["refresh_token"]
    assert_not_includes raw["refresh_token"], SECRET_REFRESH

    reloaded = HackatimeConnection.find(connection.id)
    assert_equal SECRET_TOKEN, reloaded.access_token
    assert_equal SECRET_REFRESH, reloaded.refresh_token
  end

  test "inspect never shows a token" do
    connection = connect_hackatime(users(:onboarded), refresh_token: SECRET_REFRESH)
    assert_not_includes connection.inspect, SECRET_TOKEN
    assert_not_includes connection.inspect, SECRET_REFRESH
  end

  test "one connection per user and one user per Hackatime id" do
    connect_hackatime(users(:onboarded), uid: "7")
    assert_not HackatimeConnection.new(user: users(:onboarded), hackatime_uid: "8", access_token: "x", connected_at: Time.current).valid?
    assert_not HackatimeConnection.new(user: users(:new_user), hackatime_uid: "7", access_token: "x", connected_at: Time.current).valid?
    assert_raises(ActiveRecord::RecordNotUnique) do
      HackatimeConnection.new(user: users(:new_user), hackatime_uid: "7", access_token: "x", connected_at: Time.current).save!(validate: false)
    end
  end

  test "the uid must be numeric and the error code a short code" do
    connection = HackatimeConnection.new(user: users(:onboarded), hackatime_uid: "abc", access_token: "x", connected_at: Time.current)
    assert_not connection.valid?
    connection.hackatime_uid = "12"
    connection.last_error_code = "Some message with spaces"
    assert_not connection.valid?
    connection.last_error_code = "rate_limited"
    assert connection.valid?
  end

  test "the database enforces the length and error code checks too" do
    connection = connect_hackatime(users(:onboarded))
    assert_raises(ActiveRecord::StatementInvalid) { connection.update_columns(last_error_code: "Free text here") }
    assert_raises(ActiveRecord::StatementInvalid) { connection.update_columns(hackatime_uid: "9" * 41) }
    assert_raises(ActiveRecord::StatementInvalid) { connection.update_columns(scopes: "x" * 101) }
  end

  test "expired? leaves a small margin and treats no expiry as never" do
    assert_not HackatimeConnection.new.expired?
    assert HackatimeConnection.new(expires_at: 30.seconds.from_now).expired?
    assert_not HackatimeConnection.new(expires_at: 10.minutes.from_now).expired?
  end

  test "deleting the user deletes the connection and its tokens" do
    user = users(:onboarded)
    connect_hackatime(user)
    assert_difference "HackatimeConnection.count", -1 do
      User.where(id: user.id).delete_all
    end
  end

  test "the foreign key to users cascades" do
    fk = ActiveRecord::Base.connection.foreign_keys("hackatime_connections").find { |key| key.to_table == "users" }
    assert_equal :cascade, fk.on_delete
  end
end
