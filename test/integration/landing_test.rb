require "test_helper"

class LandingTest < ActionDispatch::IntegrationTest
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

  test "renders for signed-out visitors with a sign up button" do
    get "/"
    assert_response :success
    assert_select "h1", "Battletown"
    assert_select "form[action='/auth/hack_club'] button", text: "Sign up with Hack Club", minimum: 1
  end

  test "lists every prize priced in hours" do
    get "/"
    assert_select ".landing-prize", Prize.all.size
    assert_select ".landing-prize__price", text: "2 hours"
    assert_select ".landing-prize__name", text: "Battletown T-shirt"
  end

  test "pages carry no inline style attributes" do
    get "/"
    assert_select "[style]", 0
  end

  test "shows a referral banner only for a known slug" do
    get "/"
    assert_select ".landing-referral", 0

    get "/haven"
    follow_redirect!
    assert_select ".landing-referral", /Welcome from Haven/

    reset!
    get "/not-a-real-slug"
    assert_response :not_found
    get "/"
    assert_select ".landing-referral", 0
  end

  test "signed-in users who haven't onboarded are offered to continue setup" do
    sign_in_as users(:new_user)
    get "/"
    assert_response :success
    assert_select "a[href='#{onboarding_path}']", text: "Continue setup", minimum: 1
    assert_select "form[action='/auth/hack_club'] button", text: "Sign up with Hack Club", count: 0
  end

  test "onboarded users are redirected to the dashboard" do
    sign_in_as users(:onboarded)
    get "/"
    assert_redirected_to dashboard_path
  end
end
