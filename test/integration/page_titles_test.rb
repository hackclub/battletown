require "test_helper"

# Browser tab titles: "Battletown" for the signed-out landing page, "Home - Battletown" by default when signed in,
# and "<Page> - Battletown" for any page that names itself (the onboarding steps), signed in or not.
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

  test "signed out landing page is exactly Battletown" do
    get "/"
    assert_response :success
    assert_select "title", text: "Battletown", count: 1
  end

  test "the signed out steps of onboarding each have their own title" do
    get onboarding_step_path("age")
    assert_select "title", text: "How old are you? - Battletown", count: 1
    patch onboarding_step_path("age"), params: { user: { age_group: "teen" } }
    get onboarding_step_path("prize")
    assert_select "title", text: "Pick your prize - Battletown", count: 1
  end

  test "signed in onboarded user sees Home - Battletown on the dashboard" do
    sign_in_as users(:onboarded)
    get dashboard_path
    assert_response :success
    assert_select "title", text: "Home - Battletown", count: 1
  end

  test "signed in but not onboarded user gets Home - Battletown on the landing page" do
    sign_in_as users(:new_user)
    get "/"
    assert_response :success
    assert_select "title", text: "Home - Battletown", count: 1
  end

  test "signed in pages that name themselves use the page name then Battletown" do
    sign_in_as users(:new_user)
    get onboarding_step_path("prize")
    assert_response :success
    assert_select "title", text: "Pick your prize - Battletown", count: 1
  end

  test "the four pages in the header name themselves" do
    sign_in_as users(:onboarded)
    { player_path(users(:onboarded).public_slug) => "My profile", shop_path => "Armoury", settings_path => "Settings" }.each do |path, name|
      get path
      assert_response :success, path
      assert_select "title", text: "#{name} - Battletown", count: 1
    end
  end

  test "the admin dashboard is titled Admin - Battletown" do
    original = ENV["ADMIN_HCA_UIDS"]
    ENV["ADMIN_HCA_UIDS"] = users(:onboarded).hca_uid
    sign_in_as users(:onboarded)
    get admin_root_path
    assert_response :success
    assert_select "title", text: "Admin - Battletown", count: 1
  ensure
    original.nil? ? ENV.delete("ADMIN_HCA_UIDS") : ENV["ADMIN_HCA_UIDS"] = original
  end

  test "an apostrophe or ampersand in a page name is escaped once, not twice" do
    sign_in_as users(:new_user)
    user = users(:new_user)
    user.update!(onboarding_step: User::ONBOARDING_STEPS)
    HackatimeConnection.create!(user: user, hackatime_uid: "6161", access_token: "t" * 20, scopes: "profile read", connected_at: Time.current)
    get onboarding_step_path("celebrate")
    assert_response :success
    assert_select "title", text: "You're in! - Battletown", count: 1
    assert_no_match(/&amp;#39;|&amp;amp;/, response.body)
  end
end
