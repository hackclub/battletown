require "test_helper"
require_relative "../support/notifications_helper"

class NotificationSettingsTest < ActionDispatch::IntegrationTest
  include NotificationsHelper

  setup do
    OmniAuth.config.test_mode = true
    @user = users(:onboarded)
    @user.update_columns(slack_id: "UTESTAAA1")
    @other = users(:new_user)
    @other.update_columns(onboarded_at: Time.utc(2026, 11, 2), onboarding_step: 4, slack_id: "UTESTBBB2")
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
  end

  def sign_in_as(user)
    claims = user.slack_id ? { "slack_id" => user.slack_id } : {}
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: claims })
    post "/auth/hack_club"
    follow_redirect!
  end

  def save(choices) = patch(settings_notifications_path, params: { preferences: choices })

  # --- access ---

  test "signed-out visitors are sent home" do
    get settings_notifications_path
    assert_redirected_to root_path
    patch settings_notifications_path, params: { preferences: { ship_approved: "0" } }
    assert_redirected_to root_path
    assert_equal 0, NotificationPreference.count
  end

  test "people who have not finished onboarding are sent to onboarding" do
    sign_in_as(users(:new_user).tap { |user| user.update_columns(onboarded_at: nil, onboarding_step: 0) })
    get settings_notifications_path
    assert_redirected_to onboarding_path
    patch settings_notifications_path, params: { preferences: { ship_approved: "0" } }
    assert_redirected_to onboarding_path
    assert_equal 0, NotificationPreference.count
  end

  # --- the screen ---

  test "the welcome-back switch is listed only while the returning feature is on" do
    sign_in_as(@user)
    get settings_notifications_path
    assert_select "input[name='preferences[returning_nudge]']", 0
    with_feature(:returning) do
      get settings_notifications_path
      assert_select "input[type=checkbox][name='preferences[returning_nudge]'][checked]"
      assert_select "label[for=preferences_returning_nudge] .notification-settings__title", text: "Welcome-back nudge"
    end
  end

  test "shows every kind with a plain label, all on by default, and a Save changes button" do
    sign_in_as(@user)
    get settings_notifications_path
    assert_response :success
    assert_select "title", /Notifications/
    assert_select "h1", "Notifications"
    assert_select "form[action=?][method=post]", settings_notifications_path
    assert_select "input[name='_method'][value=patch]"
    (Notification::KINDS - %w[returning_nudge]).each do |kind|
      assert_select "input[type=checkbox][name='preferences[#{kind}]'][checked]"
      assert_select "input[type=hidden][name='preferences[#{kind}]'][value='0']"
      assert_select "label[for=preferences_#{kind}] .notification-settings__title", text: Notifications::Config.current.label(kind)["title"]
    end
    assert_select "input[type=submit][value='Save changes']"
    assert_select ".notification-settings__note", count: 0
    assert_equal "no-store", response.headers["Cache-Control"]
  end

  test "the header links to it for onboarded people" do
    sign_in_as(@user)
    get dashboard_path
    assert_select "nav a[href=?]", settings_notifications_path, text: "Notifications"
  end

  test "tells people without a Slack id that nothing can be sent yet" do
    @user.update_columns(slack_id: nil)
    sign_in_as(@user)
    get settings_notifications_path
    assert_select ".notification-settings__note", /isn't linked to a Slack account/
  end

  test "the page never shows the Slack id" do
    sign_in_as(@user)
    get settings_notifications_path
    assert_no_match(/UTESTAAA1/, response.body)
  end

  # --- saving ---

  test "saving switches kinds off and on, with a friendly flash" do
    sign_in_as(@user)
    save(Notification::KINDS.index_with { "1" }.merge("ship_reminder" => "0", "link_question" => "0"))
    assert_redirected_to settings_notifications_path
    follow_redirect!
    assert_select ".flash--notice", /Saved/
    assert_select "input[name='preferences[ship_reminder]'][checked]", count: 0
    assert_select "input[name='preferences[link_question]'][checked]", count: 0
    assert_select "input[name='preferences[ship_mvp]'][checked]"
    assert_not Notifications::Preferences.enabled?(@user, "ship_reminder")
    assert Notifications::Preferences.enabled?(@user, "ship_mvp")

    save("ship_reminder" => "1")
    assert Notifications::Preferences.enabled?(@user, "ship_reminder")
    assert_equal 1, NotificationPreference.where(user_id: @user.id, kind: "ship_reminder").count, "one row per kind"
  end

  test "someone can only change their own switches, whatever the request says" do
    sign_in_as(@user)
    save("ship_approved" => "0", "user_id" => @other.id, "preferences" => { "user_id" => @other.id })
    patch settings_notifications_path, params: { user_id: @other.id, preferences: { ship_approved: "0", user_id: @other.id } }

    assert_not Notifications::Preferences.enabled?(@user, "ship_approved")
    assert Notifications::Preferences.enabled?(@other, "ship_approved")
    assert_equal [ @user.id ], NotificationPreference.pluck(:user_id).uniq
  end

  test "each person sees their own choices" do
    Notifications::Preferences.update!(@other, "ship_approved" => "0")
    sign_in_as(@user)
    get settings_notifications_path
    assert_select "input[name='preferences[ship_approved]'][checked]"
  end

  test "unknown kinds and junk values are ignored" do
    sign_in_as(@user)
    save("nonsense" => "0", "ship_approved" => "maybe", "ship_mvp" => [ "0" ])
    assert_response :redirect
    assert_equal 0, NotificationPreference.count
    patch settings_notifications_path, params: { preferences: "junk" }
    assert_response :redirect
    patch settings_notifications_path
    assert_response :redirect
    assert_equal 0, NotificationPreference.count
  end

  test "turning the daily reminder off cancels the queued one and turning it on queues it again" do
    Notifications::Scheduler.schedule_next(@user)
    assert_equal 1, Notification.pending.where(user_id: @user.id, kind: "daily_reminder").count
    sign_in_as(@user)

    save("daily_reminder" => "0")
    assert_equal 0, Notification.pending.where(user_id: @user.id, kind: "daily_reminder").count

    save("daily_reminder" => "1")
    assert_equal 1, Notification.pending.where(user_id: @user.id, kind: "daily_reminder").count
  end

  test "a scheduler failure never breaks saving" do
    sign_in_as(@user)
    original = Notifications::Scheduler.method(:schedule_next)
    Notifications::Scheduler.define_singleton_method(:schedule_next) { |*, **| raise "boom" }
    logs = capture_logs { save("ship_approved" => "0") }
    assert_redirected_to settings_notifications_path
    assert_not Notifications::Preferences.enabled?(@user, "ship_approved")
    assert_includes logs, "notifications.schedule_failed error=RuntimeError"
  ensure
    Notifications::Scheduler.define_singleton_method(:schedule_next, original)
  end

  test "saving is rate limited" do
    Rack::Attack.enabled = true
    Rack::Attack.cache.store.clear
    sign_in_as(@user)
    20.times { save("ship_mvp" => "1") }
    assert_response :redirect
    save("ship_mvp" => "1")
    assert_response :too_many_requests
    get settings_notifications_path
    assert_response :success
  ensure
    Rack::Attack.cache.store.clear
    Rack::Attack.enabled = false
  end
end
