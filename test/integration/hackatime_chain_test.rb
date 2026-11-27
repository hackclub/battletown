require "test_helper"
require_relative "../support/hackatime_helper"

# Straight after Hack Club sign-in, someone with no working Hackatime link is sent on to Hackatime (like Save Point's
# sign-in chain): a page that posts itself to Hackatime's OAuth, then back to where the person belongs.
class HackatimeChainTest < ActionDispatch::IntegrationTest
  include HackatimeHelper

  setup do
    OmniAuth.config.test_mode = true
    @chain_before = Rails.configuration.x.hackatime.sign_in_chain
    Rails.configuration.x.hackatime.sign_in_chain = true
  end

  teardown do
    Rails.configuration.x.hackatime.sign_in_chain = @chain_before
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
    OmniAuth.config.mock_auth[:hackatime] = nil
  end

  # Signs in through the mocked Hack Club callback; the response is sign-in's own redirect (not followed).
  def sign_in_with_hack_club(user)
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
  end

  def mock_hackatime(uid: "4242")
    OmniAuth.config.mock_auth[:hackatime] = OmniAuth::AuthHash.new(provider: "hackatime", uid: uid, credentials: { "token" => SECRET_TOKEN, "scope" => "profile read" })
  end

  test "sign-in goes on to the Hackatime step for someone with no link, then to Hackatime's OAuth" do
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: users(:new_user).hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
    assert_redirected_to sign_in_hackatime_path

    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    follow_redirect!
    assert_response :success
    assert_select "title", /One more step/
    assert_select "h1", /One more step: Hackatime/
    assert_select "form[action='/auth/hackatime'][method=post][data-turbo=false][data-controller='auto-submit'] button", "Continue to Hackatime"
    assert_select "input[name=authenticity_token]", 1
    assert_select ".site-header, .site-footer", 0
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  test "the page exists once per sign-in: a reload or a link goes on to where the person belongs" do
    sign_in_with_hack_club(users(:new_user))
    get sign_in_hackatime_path
    assert_response :success
    get sign_in_hackatime_path
    assert_redirected_to onboarding_path

    sign_in_with_hack_club(users(:onboarded))
    get sign_in_hackatime_path
    assert_response :success
    get sign_in_hackatime_path
    assert_redirected_to dashboard_path
  end

  test "a visitor who is not signed in gets nothing from the step page" do
    get sign_in_hackatime_path
    assert_redirected_to root_path
  end

  test "someone who already has a working link signs in as before, and a link that needs reconnecting is chained again" do
    user = users(:new_user)
    connect_hackatime(user)
    sign_in_with_hack_club(user)
    assert_redirected_to onboarding_path

    user.hackatime_connection.update!(needs_reconnect: true)
    sign_in_with_hack_club(user)
    assert_redirected_to sign_in_hackatime_path
  end

  test "with the chain switched off (HACKATIME_CHAIN=0 or no OAuth app) sign-in is unchanged" do
    Rails.configuration.x.hackatime.sign_in_chain = false
    sign_in_with_hack_club(users(:new_user))
    assert_redirected_to onboarding_path
  end

  test "the chain option is a real true or false (a name like `chain` would be Enumerable#chain and always truthy)" do
    assert_includes [ true, false ], Rails.configuration.x.hackatime.sign_in_chain
    Rails.configuration.x.hackatime.sign_in_chain = false
    assert_equal false, Rails.configuration.x.hackatime.sign_in_chain
  end

  test "the config turns the chain on only when the OAuth app is set up, and HACKATIME_CHAIN=0 turns it off" do
    source = File.read(Rails.root.join("config/application.rb"))
    assert_match(/sign_in_chain = .*client_id\.present\?.*client_secret\.present\?.*HACKATIME_CHAIN"\] != "0"/, source)
  end

  test "a visitor's whole sign-up: draft, sign-in, the chain, Hackatime, then back on the account step with everything kept" do
    patch onboarding_step_path("age"), params: { user: { age_group: "teen" } }
    patch onboarding_step_path("prize"), params: { user: { prize_key: "tshirt" } }
    patch onboarding_step_path("project"), params: { user: { project_kind: "game" } }
    patch onboarding_step_path("schedule"), params: { user: { coding_day_names: %w[monday], coding_time: "18:30", time_zone: "UTC" } }

    newcomer = User.new(hca_uid: "ident!chained")
    sign_in_with_hack_club(newcomer)
    assert_redirected_to sign_in_hackatime_path
    follow_redirect!
    assert_response :success

    mock_hackatime(uid: "7001")
    get "/auth/hackatime/callback"
    assert_redirected_to onboarding_step_path("account")
    user = User.find_by!(hca_uid: "ident!chained")
    assert_equal "tshirt", user.prize_key
    assert_equal 5, user.onboarding_step
    assert user.hackatime_connection.present?

    follow_redirect!
    assert_select "#hackatime-check .badge", "Connected"
    assert_select "button", text: "Continue"
  end

  test "someone who is already in and was chained lands on the dashboard after linking, not on the Hackatime page" do
    sign_in_with_hack_club(users(:onboarded))
    get sign_in_hackatime_path
    mock_hackatime(uid: "7002")
    get "/auth/hackatime/callback"
    assert_redirected_to dashboard_path
    assert users(:onboarded).reload.hackatime_connection.present?
  end

  test "a refused or failed link from the chain goes back to the account step or the dashboard, and is never chained again" do
    users(:new_user).update!(onboarding_step: 5) # where someone who just signed up at the end of onboarding is
    sign_in_with_hack_club(users(:new_user))
    get sign_in_hackatime_path
    get "/auth/failure", params: { strategy: "hackatime", message: "access_denied" }
    assert_redirected_to onboarding_step_path("account")
    follow_redirect!
    assert_select ".onboarding__flash", /You need it to finish signing up/ # not "whenever you're ready": it is required here
    get sign_in_hackatime_path # the flag was used up
    assert_redirected_to onboarding_path

    sign_in_with_hack_club(users(:onboarded))
    get sign_in_hackatime_path
    get "/auth/failure", params: { strategy: "hackatime", message: "invalid_credentials" }
    assert_redirected_to dashboard_path
    follow_redirect!
    assert_select ".flash", /couldn't connect to Hackatime/i
  end

  test "a link started from a page (not the chain) still ends where it always did" do
    sign_in_with_hack_club(users(:onboarded))
    get sign_in_hackatime_path # uses up the sign-in's flag, leaving no chain marker once the callback runs
    mock_hackatime(uid: "7003")
    get "/auth/hackatime/callback"
    assert_redirected_to dashboard_path
    delete hackatime_path
    mock_hackatime(uid: "7004")
    get "/auth/hackatime/callback"
    assert_redirected_to hackatime_path # no chain this time: someone on the Hackatime page connecting again
  end
end
