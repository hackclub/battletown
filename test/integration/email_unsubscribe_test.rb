require "test_helper"
require_relative "../support/email_helper"

# GET/POST /email/unsubscribe/:token (EmailUnsubscribesController), and the /settings/notifications email section.
class EmailUnsubscribeTest < ActionDispatch::IntegrationTest
  include EmailHelper

  setup do
    OmniAuth.config.test_mode = true
    @detailed = Rails.application.env_config["action_dispatch.show_detailed_exceptions"]
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = false
    @user = users(:onboarded)
    @user.update_columns(email: "teen@example.test", slack_id: "UTESTEML1")
    @token = Notifications::Email::UnsubscribeToken.generate(@user)
    @path = "/email/unsubscribe/#{@token}"
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = @detailed
  end

  def sign_in_as(user)
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
  end

  def with_forgery_protection
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    yield
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  # --- the flag ---

  test "with the email flag off the routes do not exist: GET and POST are a 404 and nothing changes" do
    get @path
    assert_response :not_found
    post @path
    assert_response :not_found
    post @path, params: { "List-Unsubscribe" => "One-Click" }
    assert_response :not_found
    assert_not @user.reload.email_opted_out?
  end

  # --- GET changes nothing ---

  test "GET shows a confirmation page with a button and changes nothing, however often a scanner fetches it" do
    with_feature(:email) do
      3.times do
        get @path
        assert_response :success
      end
      assert_select "h1", "Stop Battletown emails?"
      assert_select "form[action='#{@path}'][method='post'] button, form[action='#{@path}'] input[type=submit]", 1
      assert_not @user.reload.email_opted_out?
    end
  end

  test "the page shows no address and no name, is not cached, hides the token from referrers and from search engines" do
    with_feature(:email) do
      get @path
      assert_not_includes response.body, "teen@example.test"
      assert_not_includes response.body, @user.display_name.to_s if @user.display_name.present?
      assert_equal "no-store", response.headers["Cache-Control"]
      assert_equal "no-referrer", response.headers["Referrer-Policy"]
      assert_match(/noindex/, response.headers["X-Robots-Tag"])
    end
  end

  test "a signed-out visitor needs no login at all" do
    with_feature(:email) do
      get @path
      assert_response :success
      post @path
      assert_response :success
      assert @user.reload.email_opted_out?
    end
  end

  # --- POST does it ---

  test "POST from the button unsubscribes, shows the result, and is idempotent" do
    with_feature(:email) do
      queued = email_row(@user)
      post @path
      assert_response :success
      assert_select "h1", "You're unsubscribed"
      first = @user.reload.email_opted_out_at
      assert first
      assert queued.reload.cancelled?

      post @path
      assert_response :success
      assert_equal first, @user.reload.email_opted_out_at

      get @path
      assert_select "h1", "You're unsubscribed"
    end
  end

  test "the RFC 8058 one-click POST (form body, no cookies, no CSRF token, no browser) works with forgery protection on" do
    with_feature(:email) do
      with_forgery_protection do
        post @path, params: { "List-Unsubscribe" => "One-Click" }, headers: { "User-Agent" => "MailProviderBot/1.0 (+https://example.test/bot)" }
        assert_response :success
        assert @user.reload.email_opted_out?
      end
    end
  end

  test "the one-click POST is not blocked by the modern-browser check" do
    with_feature(:email) do
      post @path, params: { "List-Unsubscribe" => "One-Click" },
                  headers: { "User-Agent" => "Mozilla/5.0 (Windows NT 5.1; rv:11.0) Gecko Firefox/11.0" }
      assert_response :success
      assert @user.reload.email_opted_out?
    end
  end

  test "unsubscribing leaves the rest of the person's settings alone" do
    with_feature(:email) do
      Notifications::Preferences.update!(@user, { "ship_rejected" => "0" }, "email")
      Notifications::Preferences.update!(@user, { "ship_approved" => "0" })
      post @path
      assert_equal({ "ship_approved" => true, "ship_rejected" => false }, Notifications::Preferences.settings(@user.reload, channel: "email").slice("ship_approved", "ship_rejected"))
      assert_not Notifications::Preferences.enabled?(@user, "ship_approved")
    end
  end

  # --- bad tokens ---

  test "bad, tampered, rotated and deleted-account tokens all get the same generic page and change nothing" do
    other = users(:new_user)
    stale = Notifications::Email::UnsubscribeToken.generate(other)
    other.update_columns(email_unsubscribe_nonce: SecureRandom.uuid)
    gone = create_email_user("gone1")
    gone_token = Notifications::Email::UnsubscribeToken.generate(gone)
    User.where(id: gone.id).delete_all

    bodies = []
    with_feature(:email) do
      [ "garbage", "#{@token}x", @token[0, 30], stale, gone_token, "a--b" ].each do |token|
        get "/email/unsubscribe/#{token}"
        assert_response :success, token
        assert_select "h1", "This link doesn't work"
        bodies << css_select("article").to_s
        post "/email/unsubscribe/#{token}"
        assert_response :success, token
        assert_select "h1", "This link doesn't work"
      end
    end
    assert_not other.reload.email_opted_out?
    assert_not @user.reload.email_opted_out?
    assert_equal 1, bodies.uniq.size, "the invalid page never differs"
  end

  test "an over-long or oddly shaped token is not even routed" do
    with_feature(:email) do
      get "/email/unsubscribe/#{'a' * 301}"
      assert_response :not_found
      get "/email/unsubscribe/a.b"
      assert_response :not_found
    end
  end

  test "a link in an old email stops working once the person turns email back on" do
    with_feature(:email) do
      post @path
      assert @user.reload.email_opted_out?
      Notifications::Email::Subscription.resubscribe!(@user)

      get @path
      assert_select "h1", "This link doesn't work"
      post @path
      assert_not @user.reload.email_opted_out?
    end
  end

  # --- CSRF is exempt for exactly this POST ---

  test "the browser button POST carries a CSRF token and works with forgery protection on" do
    with_feature(:email) do
      with_forgery_protection do
        get @path
        post @path, params: { authenticity_token: css_select("form input[name=authenticity_token]").first["value"] }
        assert_select "h1", "You're unsubscribed"
      end
    end
  end

  # --- the settings page ---

  test "settings show no email section and ignore email parameters while the flag is off" do
    sign_in_as @user
    get settings_notifications_path
    assert_response :success
    assert_select "#email-settings", 0
    assert_no_match(/Email me|Send me email/, response.body)

    patch settings_notifications_path, params: { email_enabled: "0", email_preferences: { ship_approved: "0" } }
    assert_redirected_to settings_notifications_path
    assert_not @user.reload.email_opted_out?
    assert_equal 0, NotificationPreference.where(user_id: @user.id, channel: "email").count
  end

  test "settings list the email switches, on by default, and save them per kind and per channel" do
    with_feature(:returning) do
     with_feature(:email) do
      sign_in_as @user
      get settings_notifications_path
      assert_select "#email-settings"
      assert_select "#email_enabled[checked]"
      Notifications::Email::KINDS.each { |kind| assert_select "#email_preferences_#{kind}[checked]" }
      assert_select "#email-settings", text: /Email me when a ship is approved/

      patch settings_notifications_path, params: { email_enabled: "1", email_preferences: { ship_approved: "0", ship_rejected: "1", daily_reminder: "0" } }
      assert_redirected_to settings_notifications_path
      assert_not Notifications::Preferences.enabled?(@user, "ship_approved", channel: "email")
      assert Notifications::Preferences.enabled?(@user, "ship_rejected", channel: "email")
      assert Notifications::Preferences.enabled?(@user, "ship_approved"), "the Slack switch is separate"
      assert_equal 0, NotificationPreference.where(user_id: @user.id, kind: "daily_reminder").count
     end
    end
  end

  test "the welcome-back email switch is hidden while the returning flag is off" do
    with_feature(:email) do
      sign_in_as @user
      get settings_notifications_path
      assert_select "#email_preferences_ship_approved"
      assert_select "#email_preferences_returning_nudge", 0
    end
  end

  test "the global switch off unsubscribes, back on rotates the nonce and retires old links" do
    with_feature(:email) do
      sign_in_as @user
      patch settings_notifications_path, params: { email_enabled: "0" }
      assert @user.reload.email_opted_out?
      get settings_notifications_path
      assert_select "#email_enabled:not([checked])"

      patch settings_notifications_path, params: { email_enabled: "1" }
      assert_not @user.reload.email_opted_out?
      assert_nil Notifications::Email::UnsubscribeToken.user_for(@token)
    end
  end

  test "saving the Slack choices alone (no email parameters) leaves the email choices as they were" do
    with_feature(:email) do
      Notifications::Preferences.update!(@user, { "ship_approved" => "0" }, "email")
      @user.update_columns(email_opted_out_at: Time.current)
      sign_in_as @user
      patch settings_notifications_path, params: { preferences: { ship_mvp: "0" } }
      assert @user.reload.email_opted_out?
      assert_not Notifications::Preferences.enabled?(@user, "ship_approved", channel: "email")
    end
  end

  test "someone with no usable address is told, and their choices are still saved" do
    with_feature(:email) do
      @user.update_columns(email: nil)
      sign_in_as @user
      get settings_notifications_path
      assert_select "#email-settings .alert", /no usable email address/
      patch settings_notifications_path, params: { email_preferences: { ship_rejected: "0" } }
      assert_not Notifications::Preferences.enabled?(@user, "ship_rejected", channel: "email")
    end
  end

  # --- throttle ---

  test "the unsubscribe page has its own rate limit" do
    Rack::Attack.enabled = true
    Rack::Attack.cache.store.clear
    with_feature(:email) do
      21.times { get @path, headers: { "REMOTE_ADDR" => "203.0.113.7" } }
      assert_response :too_many_requests
    end
  ensure
    Rack::Attack.enabled = false
  end
end
