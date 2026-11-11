require "test_helper"

class AccessTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
  end

  def sign_in_as(user)
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
  end

  test "un-onboarded users are sent to onboarding from the dashboard" do
    sign_in_as users(:new_user)
    get "/dashboard"
    assert_redirected_to onboarding_path
    get "/onboarding"
    assert_response :success
  end

  test "onboarded users see the dashboard and skip the landing page" do
    sign_in_as users(:onboarded)
    get "/dashboard"
    assert_response :success
    assert_select "strong", /T-shirt/
    get "/"
    assert_redirected_to dashboard_path
  end

  test "a session pointing at a deleted user is cleared" do
    sign_in_as users(:onboarded)
    users(:onboarded).destroy
    get "/dashboard"
    assert_redirected_to root_path
    assert_nil session[:user_id]
  end
end
