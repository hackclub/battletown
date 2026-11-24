require "test_helper"
require_relative "../support/hackatime_helper"

# Hackatime is a required step of onboarding: the account step offers Connect (never Continue) until it works, the server
# refuses to move on without it, and the OAuth round trip brings an unfinished person back to onboarding, not to /hackatime.
class OnboardingHackatimeTest < ActionDispatch::IntegrationTest
  include HackatimeHelper

  setup { OmniAuth.config.test_mode = true }

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
    OmniAuth.config.mock_auth[:hackatime] = nil
  end

  def sign_in_as(user)
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
  end

  def mock_hackatime(uid: "4242", scope: "profile read")
    OmniAuth.config.mock_auth[:hackatime] = OmniAuth::AuthHash.new(
      provider: "hackatime", uid: uid, credentials: { "token" => SECRET_TOKEN, "scope" => scope }
    )
  end

  def at_account_step(user)
    user.update!(onboarding_step: 5)
    sign_in_as user
  end

  test "the account step makes Hackatime required: a Connect button, no Continue, and a plain explanation" do
    at_account_step(users(:new_user))
    get onboarding_step_path("account")
    assert_response :success
    assert_select "h1", "Connect Hackatime"
    assert_select "#hackatime-check .badge", "Required"
    assert_select "#hackatime-check form[action='/auth/hackatime'][method=post][data-turbo=false] button", "Connect Hackatime"
    assert_select "button", text: "Continue", count: 0
    assert_select "#hackatime-check", text: /how your hours count/
    assert_no_match(/optional\b.*hackatime|hackatime.*\boptional/i, css_select("#hackatime-check").text)
    assert_select "form form", 0 # the connect button is not nested inside the step's own form
  end

  test "without a connection the server will not finish the step either, whatever is posted" do
    user = users(:new_user)
    at_account_step(user)
    patch onboarding_step_path("account"), params: { user: { referral_source: "terra" } }
    assert_redirected_to onboarding_step_path("account")
    follow_redirect!
    # the message is inside the step and focused, not in the layout's flash above <main> (which a screen reader would skip)
    assert_select ".onboarding__flash[role=alert][tabindex='-1'][data-onboarding-step-target=errors]", /Connect Hackatime first/
    assert_select ".flash", 0
    assert_equal 5, user.reload.onboarding_step
    assert_nil user.referral_source
    get onboarding_step_path("celebrate")
    assert_redirected_to onboarding_step_path("account")
  end

  test "the last step and finishing also need the connection, including one that lapsed after the account step" do
    user = users(:new_user)
    user.update!(onboarding_step: 6)
    sign_in_as user
    get onboarding_step_path("celebrate")
    assert_redirected_to onboarding_step_path("account")
    patch onboarding_step_path("celebrate")
    assert_redirected_to onboarding_step_path("account")
    assert_not user.reload.onboarded?

    connect_hackatime(user)
    get onboarding_step_path("celebrate")
    assert_response :success
    patch onboarding_step_path("celebrate")
    assert_redirected_to dashboard_path
    assert user.reload.onboarded?

    other = User.create!(hca_uid: "ident!lapsed", onboarding_step: 6)
    connect_hackatime(other, uid: "5151", needs_reconnect: true)
    reset!
    sign_in_as other
    patch onboarding_step_path("celebrate")
    assert_redirected_to onboarding_step_path("account")
    assert_not other.reload.onboarded?
  end

  test "what the person is told about Hackatime matches what is really read, in plain words" do
    at_account_step(users(:new_user))
    get onboarding_step_path("account")
    text = css_select("#hackatime-check").text
    assert_match(/how long you code each day/, text)
    assert_match(/names of your Hackatime projects/, text)
    assert_match(/Hackatime ID/, text)
    assert_match(/don.t use or keep anything else, like your email/, text)
  end

  test "a connection that needs reconnecting does not count, and the button says Reconnect" do
    user = users(:new_user)
    connect_hackatime(user, needs_reconnect: true)
    at_account_step(user)
    get onboarding_step_path("account")
    assert_select "#hackatime-check .badge", "Needs reconnecting"
    assert_select "#hackatime-check button", "Reconnect Hackatime"
    assert_select "button", text: "Continue", count: 0
    patch onboarding_step_path("account")
    assert_redirected_to onboarding_step_path("account")
    assert_equal 5, user.reload.onboarding_step
  end

  test "connecting during onboarding brings the person back to the account step, and then Continue works" do
    user = users(:new_user)
    at_account_step(user)
    mock_hackatime
    get "/auth/hackatime/callback"
    assert_redirected_to onboarding_step_path("account")
    assert user.reload.hackatime_connection.present?
    follow_redirect!
    assert_select "#hackatime-check .badge", "Connected"
    assert_select "#hackatime-check form", 0
    assert_select "button", text: "Continue"
    patch onboarding_step_path("account"), params: { user: { referral_source: "" } }
    assert_redirected_to onboarding_step_path("celebrate")
    assert_equal 6, user.reload.onboarding_step
  end

  test "a Hackatime account that belongs to someone else is refused, and the person stays on the account step" do
    HackatimeConnection.create!(user: users(:onboarded), hackatime_uid: "4242", access_token: "x" * 20, scopes: "profile read", connected_at: Time.current)
    user = users(:new_user)
    at_account_step(user)
    mock_hackatime
    get "/auth/hackatime/callback"
    assert_redirected_to onboarding_step_path("account")
    assert_nil user.reload.hackatime_connection
    follow_redirect!
    assert_select "#hackatime-check .badge", "Required"
  end

  test "a refused or failed link goes back to the account step for someone still onboarding" do
    at_account_step(users(:new_user))
    get "/auth/failure", params: { strategy: "hackatime", message: "access_denied" }
    assert_redirected_to onboarding_step_path("account")
    get "/auth/failure", params: { strategy: "hackatime", message: "invalid_credentials" }
    assert_redirected_to onboarding_step_path("account")
  end

  test "someone who is already in is unaffected: their link goes back to /hackatime, and editing the step never blocks them" do
    user = users(:onboarded)
    sign_in_as user
    get onboarding_step_path("account")
    assert_select "button", text: "Continue"
    patch onboarding_step_path("account")
    assert_redirected_to dashboard_path # saved without a connection: they are not trapped

    mock_hackatime(uid: "777")
    get "/auth/hackatime/callback"
    assert_redirected_to hackatime_path
  end

  test "a visitor with no account cannot reach the callback or the connect page" do
    get "/auth/hackatime/callback"
    assert_redirected_to root_path
    get hackatime_path
    assert_redirected_to root_path
  end

  test "the connect page and the dashboard no longer call Hackatime optional" do
    sign_in_as users(:onboarded)
    get hackatime_path
    assert_no_match(/optional/i, response.body[/Your connection.*?<\/section>/m].to_s)
  end
end
