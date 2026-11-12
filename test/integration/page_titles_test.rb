require "test_helper"

# Browser tab titles: "BattleTown" when signed out, "Home - BattleTown" by default when signed in,
# and "<Page> - BattleTown" for signed-in pages that name themselves (onboarding steps, legal pages).
class PageTitlesTest < ActionDispatch::IntegrationTest
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

  test "signed out landing page is exactly BattleTown" do
    get "/"
    assert_response :success
    assert_select "title", text: "BattleTown", count: 1
  end

  test "signed out legal pages are exactly BattleTown" do
    [ privacy_path, terms_path ].each do |path|
      get path
      assert_response :success
      assert_select "title", text: "BattleTown", count: 1
    end
  end

  test "signed in onboarded user sees Home - BattleTown on the dashboard" do
    sign_in_as users(:onboarded)
    get dashboard_path
    assert_response :success
    assert_select "title", text: "Home - BattleTown", count: 1
  end

  test "signed in but not onboarded user gets Home - BattleTown on the landing page" do
    sign_in_as users(:new_user)
    get "/"
    assert_response :success
    assert_select "title", text: "Home - BattleTown", count: 1
  end

  test "signed in pages that name themselves use the page name then BattleTown" do
    sign_in_as users(:new_user)
    get privacy_path
    assert_select "title", text: "Privacy - BattleTown", count: 1
    get terms_path
    assert_select "title", text: "Terms - BattleTown", count: 1
    get onboarding_step_path("prize")
    assert_response :success
    assert_select "title", text: "Pick your prize - BattleTown", count: 1
  end

  test "the admin dashboard is titled Admin - BattleTown" do
    original = ENV["ADMIN_HCA_UIDS"]
    ENV["ADMIN_HCA_UIDS"] = users(:onboarded).hca_uid
    sign_in_as users(:onboarded)
    get admin_root_path
    assert_response :success
    assert_select "title", text: "Admin - BattleTown", count: 1
  ensure
    original.nil? ? ENV.delete("ADMIN_HCA_UIDS") : ENV["ADMIN_HCA_UIDS"] = original
  end

  test "an apostrophe or ampersand in a page name is escaped once, not twice" do
    sign_in_as users(:new_user)
    user = users(:new_user)
    user.update!(onboarding_step: User::ONBOARDING_STEPS)
    get onboarding_step_path("celebrate")
    assert_response :success
    assert_select "title", text: "You're in! - BattleTown", count: 1
    assert_no_match(/&amp;#39;|&amp;amp;/, response.body)
  end
end
