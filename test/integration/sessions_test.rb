require "test_helper"

class SessionsTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(
      provider: "hack_club",
      uid: "ident!mock",
      extra: { raw_info: { name: "Mock", email: "mock@example.com", slack_id: "U999", verification_status: "verified", ysws_eligible: true } }
    )
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
  end

  def sign_in_via_hca
    post "/auth/hack_club"
    follow_redirect!
  end

  test "GET to the auth request path is not allowed" do
    OmniAuth.config.test_mode = false
    get "/auth/hack_club"
    assert_response :not_found
  end

  test "signup creates a user and sends them to onboarding" do
    assert_difference "User.count", 1 do
      sign_in_via_hca
    end
    assert_redirected_to onboarding_path
    user = User.find_by!(hca_uid: "ident!mock")
    assert_equal "U999", user.slack_id
    assert user.verification_verified?
  end

  test "returning onboarded user goes to the dashboard" do
    OmniAuth.config.mock_auth[:hack_club].uid = users(:onboarded).hca_uid
    assert_no_difference "User.count" do
      sign_in_via_hca
    end
    assert_redirected_to dashboard_path
  end

  test "referral captured before signup is stored on new users only" do
    get "/haven"
    sign_in_via_hca
    assert_equal "haven", User.find_by!(hca_uid: "ident!mock").referral_source

    delete "/logout"
    get "/terra"
    sign_in_via_hca
    assert_equal "haven", User.find_by!(hca_uid: "ident!mock").referral_source
  end

  test "sign-in resets the session to prevent fixation" do
    get "/haven"
    before = request.session.id.to_s
    sign_in_via_hca
    assert_not_equal before, request.session.id.to_s
    assert_nil session[:referral_source]
    assert_equal User.find_by!(hca_uid: "ident!mock").id, session[:user_id]
  end

  test "callback without a valid auth payload fails generically" do
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "other", uid: "x")
    sign_in_via_hca
    assert_redirected_to root_path
    assert_match(/couldn't sign you in/, flash[:alert])
    assert_nil session[:user_id]
  end

  test "failure endpoint does not echo parameters" do
    get "/auth/failure", params: { message: "<script>alert(1)</script>" }
    assert_redirected_to root_path
    assert_no_match(/script/, flash[:alert])
  end

  test "logout clears the session" do
    sign_in_via_hca
    delete "/logout"
    assert_redirected_to root_path
    assert_nil session[:user_id]
  end

  test "dev login is a 404 outside development" do
    assert_no_difference "User.count" do
      post "/dev_login"
    end
    assert_response :not_found
  end

  test "dev login works in development" do
    original = Rails.env
    begin
      Rails.env = "development"
      post "/dev_login"
    ensure
      Rails.env = original
    end
    assert_redirected_to onboarding_path
    assert_equal User.find_by!(hca_uid: "dev-user").id, session[:user_id]
  end
end
