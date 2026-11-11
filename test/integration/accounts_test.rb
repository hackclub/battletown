require "test_helper"

class AccountsTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
  end

  def sign_in_as(user_or_uid)
    uid = user_or_uid.respond_to?(:hca_uid) ? user_or_uid.hca_uid : user_or_uid
    # Sign-in re-applies the claims, so send the fixture's own email back as Hack Club Auth would.
    raw_info = user_or_uid.respond_to?(:hca_uid) ? { email: user_or_uid.email, name: user_or_uid.display_name } : {}
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: uid, extra: { raw_info: raw_info })
    post "/auth/hack_club"
    follow_redirect!
  end

  def go_stale
    travel_to((AccountSettings.recent_login_window + 1.minute).from_now)
  end

  teardown { travel_back }

  # --- logged out ---------------------------------------------------------

  test "logged-out visitors cannot reach any account page or action" do
    get "/account"
    assert_redirected_to root_path
    get "/account/export"
    assert_redirected_to root_path
    get "/account/delete"
    assert_redirected_to root_path
    get "/account/reauth"
    assert_redirected_to root_path
    assert_no_difference "User.count" do
      delete "/account", params: { confirmation: AccountSettings.delete_phrase }
    end
    assert_redirected_to root_path
  end

  # --- the account page ---------------------------------------------------

  test "the account page shows the person's own data, links to export and delete, and is not cached" do
    sign_in_as users(:onboarded)
    get "/account"
    assert_response :success
    assert_select "title", text: "Your account - BattleTown"
    assert_select "dd", text: "done@example.com"
    assert_select "dd", text: "Veteran"
    assert_select "a[href='#{account_export_path}'][data-turbo='false']", text: "Download my data"
    assert_select "a[href='#{delete_account_path}']", text: "Delete my account"
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_select "header a[href='#{account_path}']", text: "Account"
  end

  test "the page uses no inline styles or scripts (CSP)" do
    sign_in_as users(:onboarded)
    [ "/account", "/account/delete" ].each do |path|
      get path
      assert_select "[style]", count: 0
      assert_select "script:not([nonce]):not([src])", count: 0
    end
  end

  # --- export ---------------------------------------------------------------

  test "export is an attachment with no-store headers, own data only, and no PII in the filename" do
    sign_in_as users(:onboarded)
    get "/account/export"

    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "no-cache", response.headers["Pragma"]
    disposition = response.headers["Content-Disposition"]
    assert_match(/\Aattachment;/, disposition)
    assert_match(/battletown-data-export-\d{8}\.json/, disposition)
    [ "Veteran", "done", "ident", "example" ].each { |pii| assert_not_includes disposition, pii }
    assert_equal "application/json", response.media_type

    body = JSON.parse(response.body)
    assert_equal "done@example.com", body.dig("data", "profile", "email")
    assert_not_includes response.body, users(:new_user).email
  end

  test "export holds no secrets, session data or Hack Club Auth tokens" do
    sign_in_as users(:onboarded)
    get "/account/export"

    %w[secret token password session csrf authenticated_at].each do |word|
      assert_not_includes response.body.downcase, word
    end
    %w[phone birthdate address].each { |key| assert_not_includes response.body, "\"#{key}\"" }
  end

  test "export ignores a user id supplied by the client" do
    sign_in_as users(:onboarded)
    get "/account/export", params: { id: users(:new_user).id, user_id: users(:new_user).id }

    assert_equal "done@example.com", JSON.parse(response.body).dig("data", "profile", "email")
  end

  # --- delete: confirmation -------------------------------------------------

  test "the confirm page shows the phrase and a CSRF-protected form that DELETEs to /account" do
    sign_in_as users(:onboarded)
    ActionController::Base.allow_forgery_protection = true
    begin
      get "/account/delete"
    ensure
      ActionController::Base.allow_forgery_protection = false
    end

    assert_response :success
    assert_select "form[action='#{account_path}']" do
      assert_select "input[name='_method'][value='delete']"
      assert_select "input[name='authenticity_token']"
      assert_select "label[for='confirmation']", text: /#{AccountSettings.delete_phrase}/
    end
    assert_equal "no-store", response.headers["Cache-Control"]
  end

  test "GET can never delete" do
    sign_in_as users(:onboarded)
    assert_no_difference "User.count" do
      get "/account", params: { confirmation: AccountSettings.delete_phrase }
      get "/account/delete", params: { confirmation: AccountSettings.delete_phrase }
      get "/account/export", params: { confirmation: AccountSettings.delete_phrase, _method: "delete" }
    end
  end

  test "a wrong, empty or differently-cased phrase deletes nothing" do
    sign_in_as users(:onboarded)
    [ "", "delete", "Delete", "DELETE MY ACCOUNT", "nope" ].each do |phrase|
      assert_no_difference "User.count" do
        delete "/account", params: { confirmation: phrase }
      end
      assert_response :unprocessable_content, phrase.inspect
      assert_select ".flash--alert", text: /nothing was deleted/
    end
    get "/dashboard"
    assert_response :success
  end

  test "a missing confirmation param deletes nothing" do
    sign_in_as users(:onboarded)
    assert_no_difference "User.count" do
      delete "/account"
    end
    assert_response :unprocessable_content
  end

  test "the right phrase deletes the account, ends the session and shows a neutral message" do
    sign_in_as users(:onboarded)
    assert_difference "User.count", -1 do
      delete "/account", params: { confirmation: AccountSettings.delete_phrase }
    end

    assert_redirected_to root_path
    assert_equal 303, response.status
    assert_not User.exists?(hca_uid: "ident!onboarded")
    assert_nil session[:user_id]
    assert_nil session[:authenticated_at]
    follow_redirect!
    assert_select ".flash--notice", text: /deleted/
    get "/dashboard"
    assert_redirected_to root_path
  end

  test "the same person can sign up again fresh after deleting" do
    sign_in_as users(:onboarded)
    delete "/account", params: { confirmation: AccountSettings.delete_phrase }

    assert_difference "User.count", 1 do
      sign_in_as "ident!onboarded"
    end
    assert_redirected_to onboarding_path
    assert_not User.find_by!(hca_uid: "ident!onboarded").onboarded?
  end

  test "deleting only ever affects the signed-in user, whatever ids are sent" do
    sign_in_as users(:onboarded)
    other = users(:new_user)
    delete "/account", params: { confirmation: AccountSettings.delete_phrase, id: other.id, user_id: other.id, user: { id: other.id } }

    assert User.exists?(other.id)
    assert_not User.exists?(hca_uid: "ident!onboarded")
  end

  test "another user's session cannot reach my data" do
    sign_in_as users(:new_user)
    get "/account/export"
    assert_not_includes response.body, "done@example.com"
    assert_equal "new@example.com", JSON.parse(response.body).dig("data", "profile", "email")
    assert_no_difference "User.where(hca_uid: 'ident!onboarded').count" do
      delete "/account", params: { confirmation: AccountSettings.delete_phrase, id: users(:onboarded).id }
    end
    assert User.exists?(hca_uid: "ident!onboarded")
  end

  test "DELETE without a CSRF token is rejected" do
    sign_in_as users(:onboarded)
    ActionController::Base.allow_forgery_protection = true
    begin
      assert_no_difference "User.count" do
        delete "/account", params: { confirmation: AccountSettings.delete_phrase }
      end
      assert_response :unprocessable_content
    ensure
      ActionController::Base.allow_forgery_protection = false
    end
  end

  # --- recent login ---------------------------------------------------------

  test "signing in stamps the session, and a fresh login can export and delete straight away" do
    sign_in_as users(:onboarded)
    assert_in_delta Time.current.to_i, session[:authenticated_at], 5
    get "/account/export"
    assert_response :success
  end

  test "a login older than the window is sent to sign in again for export, confirm and delete" do
    sign_in_as users(:onboarded)
    go_stale

    get "/account/export"
    assert_redirected_to reauth_account_path
    get "/account/delete"
    assert_redirected_to reauth_account_path
    assert_no_difference "User.count" do
      delete "/account", params: { confirmation: AccountSettings.delete_phrase }
    end
    assert_redirected_to reauth_account_path
    # Still signed in for ordinary pages.
    get "/account"
    assert_response :success
  end

  test "the sign-in-again page runs the real Hack Club Auth form, then returns to the account page for export" do
    sign_in_as users(:onboarded)
    go_stale
    get "/account/export"
    follow_redirect!

    assert_response :success
    assert_select "form[action='/auth/hack_club'][data-turbo='false']"
    assert_select "button", text: "Sign in again with Hack Club"

    post "/auth/hack_club"
    follow_redirect!
    assert_redirected_to account_path
    follow_redirect!
    assert_select ".flash--notice", text: /signed in again/
    get "/account/export"
    assert_response :success
  end

  test "after signing in again for delete you land on the confirmation page, and delete works" do
    sign_in_as users(:onboarded)
    go_stale
    get "/account/delete"
    follow_redirect!
    post "/auth/hack_club"
    follow_redirect!
    assert_redirected_to delete_account_path
    follow_redirect!
    assert_response :success
    assert_difference "User.count", -1 do
      delete "/account", params: { confirmation: AccountSettings.delete_phrase }
    end
  end

  test "signing in again as a different account is refused and nothing is deleted or created" do
    sign_in_as users(:onboarded)
    go_stale
    get "/account/delete"
    follow_redirect!

    assert_no_difference "User.count" do
      sign_in_as "ident!someone-else"
    end
    assert_redirected_to account_path
    follow_redirect!
    assert_select ".flash--alert", text: /different Hack Club account/
    assert_not User.exists?(hca_uid: "ident!someone-else")
    assert User.exists?(hca_uid: "ident!onboarded")

    # The original session is untouched and still stale, so deleting still needs a proper re-sign-in.
    assert_no_difference "User.count" do
      delete "/account", params: { confirmation: AccountSettings.delete_phrase }
    end
    assert_redirected_to reauth_account_path
  end

  test "the return target cannot be set by the client" do
    sign_in_as users(:onboarded)
    go_stale
    get "/account/export", params: { return_to: "https://evil.example/", target: "https://evil.example/" }
    follow_redirect!
    post "/auth/hack_club", params: { return_to: "https://evil.example/" }
    follow_redirect!
    assert_redirected_to account_path
  end

  test "a re-sign-in marker is allowlisted and expires" do
    sign_in_as users(:onboarded)
    go_stale
    get "/account/export"
    travel((AccountSettings.recent_login_window + 1.minute))
    # Marker too old: this is an ordinary sign-in, not a re-auth, so a different account just signs in normally.
    sign_in_as "ident!someone-else"
    assert_redirected_to onboarding_path
  end

  test "the reauth page without a pending request goes back to the account page" do
    sign_in_as users(:onboarded)
    get "/account/reauth"
    assert_redirected_to account_path
  end

  # --- logging --------------------------------------------------------------

  test "export and deletion leave no personal data in the log" do
    user = users(:onboarded)
    sign_in_as user
    io = StringIO.new
    old_rails = Rails.logger
    old_action = ActionController::Base.logger
    Rails.logger = ActionController::Base.logger = ActiveSupport::Logger.new(io)
    begin
      get "/account"
      get "/account/export"
      get "/account/delete"
      delete "/account", params: { confirmation: AccountSettings.delete_phrase }
    ensure
      Rails.logger = old_rails
      ActionController::Base.logger = old_action
    end

    log = io.string
    assert_includes log, "Account deleted"
    [ user.email, user.display_name, user.hca_uid, user.id.to_s, user.slack_id.to_s ].reject(&:empty?).each do |pii|
      assert_not_includes log, pii
    end
  end
end
