require "test_helper"

# "I've verified, refresh": verification is only read at sign-in, so the locked notes carry a button into the normal Hack Club
# sign-in that comes back to the same page. The page rides along as a `return_to` param, so it is checked (SignInReturn).
class VerifiedRefreshTest < ActionDispatch::IntegrationTest
  SENTENCE = "Finished verifying with Hack Club? Sign in again to update.".freeze

  setup do
    OmniAuth.config.test_mode = true
    @user = users(:onboarded)
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
  end

  def sign_in_as(user, return_to: nil, raw_info: {})
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: raw_info })
    post "/auth/hack_club", params: (return_to.nil? ? {} : { return_to: return_to })
    follow_redirect!
  end

  def assert_refresh_button(scope, return_to)
    assert_select "#{scope} .verify-refresh .verify-refresh__text", text: SENTENCE
    assert_select "#{scope} .verify-refresh form[action='/auth/hack_club'][method=post]" do
      assert_select "input[type=hidden][name=return_to][value='#{return_to}']", 1
      assert_select "button", text: "I've verified, refresh"
    end
  end

  # --- the notes ---

  test "the armoury note offers the refresh button when unverified and when pending, and not when verified" do
    sign_in_as @user
    get shop_path
    assert_refresh_button "#shop-verify-note", "/shop"

    @user.update_columns(verification_status: "pending")
    get shop_path
    assert_select "#shop-verify-note", /being reviewed/
    assert_refresh_button "#shop-verify-note", "/shop"

    @user.update_columns(verification_status: "verified")
    get shop_path
    assert_select ".verify-refresh", 0
  end

  test "the armoury's re-check button for an old verification also comes back to the armoury" do
    sign_in_as @user
    @user.update_columns(verification_status: "verified", ysws_eligible: true, verification_checked_at: 400.days.ago)
    Flipper.enable(:eligibility_gate)
    get shop_path
    assert_select "#shop-verify-note form[action='/auth/hack_club'] input[name=return_to][value='/shop']", 1
    assert_select ".verify-refresh", 0
  end

  test "a signed-out sign-in button carries no return_to" do
    get root_path
    assert_select "form[action='/auth/hack_club'] input[name=return_to]", 0
  end

  # --- coming back ---

  test "pressing it signs in again, reads the new verification and lands on the same page, unlocked" do
    @user.update_columns(verification_status: "pending")
    sign_in_as @user
    get shop_path
    assert_select "#shop-verify-note"

    sign_in_as @user, return_to: "/shop", raw_info: { verification_status: "verified", ysws_eligible: true }
    assert_redirected_to shop_path
    follow_redirect!
    assert_response :success
    assert_equal shop_path, request.path
    assert @user.reload.verification_verified?
    assert_select "#shop-verify-note", 0
    assert_select ".shop-balance .badge--success", text: "Verified"
  end

  test "the sign-in is still the normal one: the session is reset on the way back" do
    get "/haven"
    before = request.session.id.to_s
    sign_in_as @user, return_to: "/shop"
    assert_equal @user.id, session[:user_id]
    assert_not_equal before, request.session.id.to_s
  end

  test "ship, merch and projects pages and the dashboard are valid places to come back to" do
    [ "/ships/12", "/ships/12/edit", "/merch", "/projects", "/dashboard", "/shop/items/tshirt", "/shop/orders/3" ].each do |path|
      delete logout_path
      sign_in_as @user, return_to: path
      assert_redirected_to path
    end
  end

  test "without a return_to, or one the person did not need, sign-in goes to the dashboard as before" do
    sign_in_as @user
    assert_redirected_to dashboard_path
  end

  test "someone who has not finished onboarding goes to onboarding, whatever return_to says" do
    sign_in_as users(:new_user), return_to: "/shop"
    assert_redirected_to onboarding_path
  end

  # --- no open redirect ---

  test "return_to can never send anyone off the site or somewhere unknown" do
    bad = [
      "https://evil.example/shop", "http://evil.example", "//evil.example", "///evil.example", "/\\evil.example", "/shop//evil.example",
      "javascript:alert(1)", "evil.example", "shop", "", "/", "/shop/../admin", "/shop/%2e%2e/admin", "/shop?next=https://evil.example",
      "/shop#x", "/shop ", " /shop", "/shop\n/x", "/SHOP", "/admin/users", "/auth/hack_club", "/logout", "/settings", "/onboarding", "/shop@evil.example",
      "/#{'a' * 300}", "/shop/#{'a' * 300}"
    ]
    bad.each do |value|
      delete logout_path
      sign_in_as @user, return_to: value
      assert_redirected_to dashboard_path, "return_to #{value.inspect} should be ignored"
    end
  end

  test "a return_to that is a list or a hash instead of a string is ignored" do
    [ { return_to: [ "/shop" ] }, { return_to: { "x" => "/shop" } } ].each do |params|
      delete logout_path
      OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: @user.hca_uid, extra: { raw_info: {} })
      post "/auth/hack_club", params: params
      follow_redirect!
      assert_redirected_to dashboard_path
    end
  end

  test "SignInReturn lets through plain section paths and nothing else" do
    assert_equal "/shop", SignInReturn.path("/shop")
    assert_equal "/shop/items/tshirt", SignInReturn.path("/shop/items/tshirt")
    assert_equal "/ships/7", SignInReturn.path("/ships/7")
    assert_nil SignInReturn.path("https://evil.example")
    assert_nil SignInReturn.path("//evil.example")
    assert_nil SignInReturn.path("/shop?x=1")
    assert_nil SignInReturn.path("/admin")
    assert_nil SignInReturn.path(nil)
    assert_nil SignInReturn.path([ "/shop" ])
    assert_nil SignInReturn.path({ "a" => "/shop" })
  end
end
