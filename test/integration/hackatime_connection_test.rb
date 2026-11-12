require "test_helper"
require_relative "../support/hackatime_helper"

# Linking a Hackatime account: the real OmniAuth strategy (state, PKCE, token exchange, profile) against a local
# fake provider, plus mocked callbacks for the controller rules. Nothing here touches the network.
class HackatimeConnectionIntegrationTest < ActionDispatch::IntegrationTest
  include HackatimeHelper

  setup do
    @fake = start_fake_hackatime
    @fake.on("POST", "/oauth/token") do |req|
      if req.form["code"] == "good-code" && FakeHackatime.pkce_matches?(req.form["code_verifier"], @challenge)
        [ 200, { "access_token" => SECRET_TOKEN, "token_type" => "Bearer", "scope" => @granted_scope || "profile read", "expires_in" => 504_911_232 } ]
      else
        [ 400, { "error" => "invalid_grant" } ]
      end
    end
    @fake.on("GET", "/api/v1/authenticated/me") do |req|
      req.headers["authorization"] == "Bearer #{SECRET_TOKEN}" ? [ 200, { "id" => 4242, "emails" => [ "x@example.com" ] } ] : [ 401, {} ]
    end
    @fake.on("POST", "/oauth/revoke") { |_req| [ 200, {} ] }
  end

  teardown do
    stop_fake_hackatime
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
    OmniAuth.config.mock_auth[:hackatime] = nil
  end

  def sign_in_as(user)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
    OmniAuth.config.test_mode = false
  end

  # Starts the real flow and returns the authorize parameters Hackatime would receive.
  def start_link
    post "/auth/hackatime"
    assert_response :redirect
    uri = URI(response.location)
    assert_equal URI(@fake.url).port, uri.port
    assert_equal "/oauth/authorize", uri.path
    Rack::Utils.parse_query(uri.query).tap { |params| @challenge = params["code_challenge"] }
  end

  def mock_hackatime(uid: "4242", token: SECRET_TOKEN, scope: "profile read", refresh_token: nil, expires_at: nil)
    OmniAuth.config.test_mode = true
    credentials = { "token" => token, "scope" => scope, "refresh_token" => refresh_token, "expires_at" => expires_at }.compact
    OmniAuth.config.mock_auth[:hackatime] = OmniAuth::AuthHash.new(provider: "hackatime", uid: uid, credentials: credentials)
  end

  test "the authorize request asks for exactly profile and read, with state and PKCE" do
    sign_in_as users(:onboarded)
    params = start_link

    assert_equal "code", params["response_type"]
    assert_equal "profile read", params["scope"]
    assert_equal Rails.configuration.x.hackatime.redirect_uri, params["redirect_uri"]
    assert_equal "S256", params["code_challenge_method"]
    assert params["state"].present?
    assert params["code_challenge"].present?
  end

  test "the redirect URI is derived from APP_URL and ends in /auth/hackatime/callback" do
    assert Rails.configuration.x.hackatime.redirect_uri.end_with?("/auth/hackatime/callback")
  end

  test "happy path: callback stores the Hackatime id and encrypted tokens for the signed-in user" do
    user = users(:onboarded)
    sign_in_as user
    params = start_link

    assert_no_difference "User.count" do
      assert_difference "HackatimeConnection.count", 1 do
        get "/auth/hackatime/callback", params: { code: "good-code", state: params["state"] }
      end
    end

    assert_redirected_to hackatime_path
    assert_equal user.id, session[:user_id]
    connection = user.reload.hackatime_connection
    assert_equal "4242", connection.hackatime_uid
    assert_equal SECRET_TOKEN, connection.access_token
    assert_equal "profile read", connection.scopes
    assert_not_nil connection.connected_at
    assert_not connection.needs_reconnect?
    assert_in_delta 504_911_232, connection.expires_at - Time.current, 60

    token_request = @fake.requests_for("POST", "/oauth/token").first
    assert_equal "authorization_code", token_request.form["grant_type"]
    assert_equal Rails.configuration.x.hackatime.redirect_uri, token_request.form["redirect_uri"]
    assert token_request.form["code_verifier"].present?

    follow_redirect!
    assert_select ".hackatime__status", text: "Connected"
    assert_no_match(/4242|#{SECRET_TOKEN}/, response.body)
  end

  test "a wrong state is refused: no connection, no token exchange, friendly message" do
    sign_in_as users(:onboarded)
    start_link

    assert_no_difference "HackatimeConnection.count" do
      get "/auth/hackatime/callback", params: { code: "good-code", state: "forged" }
      follow_redirect!
    end

    assert_redirected_to hackatime_path
    assert_match(/couldn't connect to Hackatime/, flash[:alert])
    assert_empty @fake.requests_for("POST", "/oauth/token")
  end

  test "denying consent at Hackatime is a friendly no-op, not an error" do
    sign_in_as users(:onboarded)
    params = start_link

    assert_no_difference "HackatimeConnection.count" do
      get "/auth/hackatime/callback", params: { error: "access_denied", state: params["state"] }
      follow_redirect!
    end

    assert_redirected_to hackatime_path
    assert_match(/No problem/, flash[:notice])
    assert_nil flash[:alert]
  end

  test "a Hackatime id already linked to another user is refused without saying who" do
    other = users(:new_user)
    connect_hackatime(other, uid: "4242", access_token: "other-token")
    user = users(:onboarded)
    sign_in_as user
    params = start_link

    assert_no_difference "HackatimeConnection.count" do
      get "/auth/hackatime/callback", params: { code: "good-code", state: params["state"] }
    end

    assert_redirected_to hackatime_path
    assert_match(/already connected to another Battletown account/, flash[:alert])
    assert_no_match(/#{other.display_name}|#{other.email}|#{other.hca_uid}/, flash[:alert])
    assert_nil user.reload.hackatime_connection
    assert_equal "other-token", other.reload.hackatime_connection.access_token
    assert_empty @fake.requests_for("POST", "/oauth/revoke"), "must not revoke: Hackatime reuses one token per person"
  end

  test "reconnecting replaces the tokens and clears needs_reconnect" do
    user = users(:onboarded)
    connect_hackatime(user, uid: "4242", access_token: "stale", needs_reconnect: true, last_error_code: "unauthorized")
    sign_in_as user
    params = start_link

    assert_no_difference "HackatimeConnection.count" do
      get "/auth/hackatime/callback", params: { code: "good-code", state: params["state"] }
    end

    connection = user.reload.hackatime_connection
    assert_equal SECRET_TOKEN, connection.access_token
    assert_not connection.needs_reconnect?
    assert_nil connection.last_error_code
  end

  test "a token without the read permission is not accepted" do
    @granted_scope = "profile"
    sign_in_as users(:onboarded)
    params = start_link

    assert_no_difference "HackatimeConnection.count" do
      get "/auth/hackatime/callback", params: { code: "good-code", state: params["state"] }
    end
    assert_match(/didn't grant the access we need/, flash[:alert])
  end

  test "a failed token exchange is a friendly failure" do
    sign_in_as users(:onboarded)
    start_link

    get "/auth/hackatime/callback", params: { code: "bad-code", state: session["omniauth.state"] }
    follow_redirect!

    assert_redirected_to hackatime_path
    assert_match(/couldn't connect to Hackatime/, flash[:alert])
    assert_equal 0, HackatimeConnection.count
  end

  test "a visitor who is not signed in cannot start a link and nothing is created" do
    assert_no_difference [ "User.count", "HackatimeConnection.count" ] do
      post "/auth/hackatime"
      assert_redirected_to "/auth/failure?message=not_signed_in&strategy=hackatime"
      follow_redirect!
    end
    assert_redirected_to root_path
    assert_match(/Sign in/, flash[:alert])
    assert_nil session[:user_id]
    assert_empty @fake.requests
  end

  test "the callback never signs anyone in or creates a user, even with a valid-looking result" do
    mock_hackatime
    assert_no_difference [ "User.count", "HackatimeConnection.count" ] do
      get "/auth/hackatime/callback"
    end
    assert_redirected_to root_path
    assert_nil session[:user_id]
  end

  test "a signed-in user who has not finished onboarding is sent to onboarding" do
    sign_in_as users(:new_user)
    mock_hackatime
    assert_no_difference "HackatimeConnection.count" do
      get "/auth/hackatime/callback"
    end
    assert_redirected_to onboarding_path
  end

  test "a mocked callback links the account for the signed-in user" do
    user = users(:onboarded)
    sign_in_as user
    mock_hackatime(uid: "99", refresh_token: SECRET_REFRESH, expires_at: 2.hours.from_now.to_i)

    get "/auth/hackatime/callback"

    assert_redirected_to hackatime_path
    connection = user.reload.hackatime_connection
    assert_equal "99", connection.hackatime_uid
    assert_equal SECRET_REFRESH, connection.refresh_token
    assert_in_delta 2.hours.from_now.to_f, connection.expires_at.to_f, 5
  end

  test "a malformed uid is refused" do
    sign_in_as users(:onboarded)
    mock_hackatime(uid: "not-a-number")
    assert_no_difference "HackatimeConnection.count" do
      get "/auth/hackatime/callback"
    end
    assert_match(/couldn't connect to Hackatime/, flash[:alert])
  end

  test "hackatime failures never reach the sign-in failure handling, and Hack Club Auth failures are unchanged" do
    get "/auth/failure", params: { message: "invalid_credentials", strategy: "hack_club" }
    assert_redirected_to root_path
    assert_match(/couldn't sign you in/, flash[:alert])
  end

  test "disconnecting deletes the tokens and asks Hackatime to revoke them, best effort" do
    user = users(:onboarded)
    connect_hackatime(user, refresh_token: SECRET_REFRESH)
    sign_in_as user

    assert_difference "HackatimeConnection.count", -1 do
      delete "/hackatime"
    end

    assert_redirected_to hackatime_path
    assert_response :see_other
    assert_nil user.reload.hackatime_connection
    revoked = @fake.requests_for("POST", "/oauth/revoke").map { |r| r.form["token"] }
    assert_equal [ SECRET_TOKEN, SECRET_REFRESH ].sort, revoked.sort
  end

  test "disconnecting still works when Hackatime is unreachable" do
    user = users(:onboarded)
    connect_hackatime(user)
    sign_in_as user
    @fake.stop

    assert_difference "HackatimeConnection.count", -1 do
      delete "/hackatime"
    end
    assert_redirected_to hackatime_path
  end

  test "disconnecting only ever touches the signed-in user's own connection" do
    other = users(:new_user)
    connect_hackatime(other, uid: "5")
    sign_in_as users(:onboarded)

    assert_no_difference "HackatimeConnection.count" do
      delete "/hackatime"
    end
    assert_not_nil other.reload.hackatime_connection
  end

  test "the page requires sign-in and onboarding" do
    get "/hackatime"
    assert_redirected_to root_path
    sign_in_as users(:new_user)
    get "/hackatime"
    assert_redirected_to onboarding_path
  end

  test "the page shows connect, connected and reconnect states" do
    user = users(:onboarded)
    sign_in_as user

    get "/hackatime"
    assert_response :success
    assert_select ".hackatime__status", text: "Not connected"
    assert_select "form[action='/auth/hackatime'][method=post][data-turbo=false] button", text: "Connect Hackatime"
    assert_select "title", text: "Hackatime - BattleTown"
    assert_select "a[href='/hackatime']", text: "Hackatime"

    connection = connect_hackatime(user, last_synced_at: 3.hours.ago)
    get "/hackatime"
    assert_select ".hackatime__status", text: "Connected"
    assert_select ".hackatime__meta", text: /Last synced about 3 hours ago/
    assert_select "form[action='/hackatime'] button", text: "Disconnect"
    assert_no_match(/#{SECRET_TOKEN}/, response.body)

    connection.update!(needs_reconnect: true)
    get "/hackatime"
    assert_select ".hackatime__status", text: "Needs reconnecting"
    assert_select "button", text: "Reconnect Hackatime"
  end

  test "the CSP lets the connect form's redirect reach Hackatime (Chrome checks form-action on redirects)" do
    sign_in_as users(:onboarded)
    get "/hackatime"
    form_action = response.headers["Content-Security-Policy"].to_s[/form-action [^;]+/]
    assert_includes form_action, "'self'"
    assert_includes form_action, "https://hackatime.hackclub.com"
    assert_includes form_action, Rails.configuration.x.hca.issuer
  end

  test "the page and the link flow keep tokens out of the log" do
    user = users(:onboarded)
    sign_in_as user
    logs = capture_logs do
      params = start_link
      get "/auth/hackatime/callback", params: { code: "good-code", state: params["state"] }
      get "/hackatime"
      delete "/hackatime"
    end
    [ SECRET_TOKEN, "good-code" ].each { |secret| assert_not_includes logs, secret }
  end

  test "token, secret, code and state parameters are filtered from logs" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter(access_token: "a", refresh_token: "r", hackatime_token: "h", client_secret: "s", code: "c", state: "t", ok: "visible")
    assert_equal({ access_token: "[FILTERED]", refresh_token: "[FILTERED]", hackatime_token: "[FILTERED]", client_secret: "[FILTERED]",
                   code: "[FILTERED]", state: "[FILTERED]", ok: "visible" }, filtered)
  end

  test "connect, callback and disconnect are throttled per IP" do
    travel_to Time.utc(2030, 1, 1, 12, 0, 0)
    Rack::Attack.enabled = true
    Rack::Attack.cache.store.clear
    headers = { "REMOTE_ADDR" => "203.0.113.50" }

    20.times { get "/auth/hackatime/callback", headers: headers }
    get "/auth/hackatime/callback", headers: headers
    assert_response :too_many_requests

    delete "/hackatime", headers: { "REMOTE_ADDR" => "203.0.113.51" }
    assert_not_equal 429, response.status
  ensure
    Rack::Attack.cache.store.clear
    Rack::Attack.enabled = false
    travel_back
  end
end
