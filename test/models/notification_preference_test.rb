require "test_helper"
require_relative "../support/notifications_helper"

class NotificationPreferenceTest < ActiveSupport::TestCase
  include NotificationsHelper

  setup { @user = create_user }

  test "every kind is on by default and an unknown kind never is" do
    Notification::KINDS.each { |kind| assert Notifications::Preferences.enabled?(@user, kind), kind }
    assert_not Notifications::Preferences.enabled?(@user, "marketing")
    assert_not Notifications::Preferences.enabled?(nil, "ship_approved")
    assert_equal Notification::KINDS, Notifications::Preferences.settings(@user).keys
    assert Notifications::Preferences.settings(@user).values.all?
  end

  test "update! stores only known kinds and clear yes or no values, and reports whether something changed" do
    assert Notifications::Preferences.update!(@user, "ship_approved" => "0", "bogus" => "0", "ship_mvp" => "perhaps")
    assert_equal [ "ship_approved" ], NotificationPreference.where(user_id: @user.id).pluck(:kind)
    assert_not Notifications::Preferences.update!(@user, "ship_approved" => "0"), "same value again changes nothing"
    assert Notifications::Preferences.update!(@user, "ship_approved" => true)
    assert Notifications::Preferences.enabled?(@user, "ship_approved")
    assert_equal 1, NotificationPreference.count
  end

  test "the model and the database both enforce the kind allowlist and one row per user and kind" do
    assert_not NotificationPreference.new(user: @user, kind: "marketing", enabled: false).valid?
    NotificationPreference.create!(user: @user, kind: "ship_mvp", enabled: false)
    assert_not NotificationPreference.new(user: @user, kind: "ship_mvp", enabled: true).valid?

    assert_raises(ActiveRecord::RecordNotUnique) do
      NotificationPreference.new(user: @user, kind: "ship_mvp", enabled: true).save!(validate: false)
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      NotificationPreference.new(user: @user, kind: "marketing", enabled: true).save!(validate: false)
    end
  end

  test "preferences and notifications are deleted with the user" do
    NotificationPreference.create!(user: @user, kind: "ship_mvp", enabled: false)
    Notifications::Outbox.enqueue(user: @user, kind: "ship_approved", subject_id: 1, key: "cascade-#{@user.id}")
    user_id = @user.id
    User.where(id: user_id).delete_all
    assert_equal 0, NotificationPreference.where(user_id: user_id).count
    assert_equal 0, Notification.where(user_id: user_id).count
  end

  test "an event notification needs a subject; the daily reminder does not" do
    base = { user: @user, status: "pending", scheduled_for: Time.current, due_at: Time.current }
    assert_not Notification.new(base.merge(kind: "ship_approved", idempotency_key: "a")).valid?
    assert Notification.new(base.merge(kind: "ship_approved", subject_id: 1, idempotency_key: "a")).valid?
    assert Notification.new(base.merge(kind: "daily_reminder", idempotency_key: "b")).valid?
  end

  test "a user can have several pending event rows but only one pending daily reminder" do
    2.times { |i| Notifications::Outbox.enqueue(user: @user, kind: "ship_reminder", subject_id: i + 1, key: "multi-#{i}") }
    assert_equal 2, Notification.pending.where(user_id: @user.id, kind: "ship_reminder").count
    Notification.create!(user: @user, kind: "daily_reminder", scheduled_for: Time.current, due_at: Time.current, idempotency_key: "d1")
    assert_raises(ActiveRecord::RecordNotUnique) do
      Notification.new(user: @user, kind: "daily_reminder", scheduled_for: 1.day.from_now, due_at: 1.day.from_now, idempotency_key: "d2").save!(validate: false)
    end
  end
end
