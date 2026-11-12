require "test_helper"

# The signed-in header: one labelled landmark, the everyday links first, Hackatime and Notifications tucked into a
# native Settings disclosure, and the current page marked for screen readers.
class HeaderNavTest < ActionDispatch::IntegrationTest
  setup { OmniAuth.config.test_mode = true }

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
  end

  def sign_in_as(user)
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
  end

  test "the everyday links come first, in order, inside a labelled Main landmark" do
    sign_in_as users(:onboarded)
    get dashboard_path
    assert_select "nav[aria-label=Main]", 1
    labels = css_select("nav[aria-label=Main] > a").map(&:text)
    assert_equal %w[Dashboard Projects Ships Shop], labels
  end

  test "Hackatime and Notifications live in the Settings disclosure, with no JavaScript needed" do
    sign_in_as users(:onboarded)
    get dashboard_path
    assert_select "nav[aria-label=Main] details.site-menu > summary", "Settings"
    assert_select "nav[aria-label=Main] details.site-menu .site-menu__panel a", 2
    assert_select "details.site-menu a[href='#{hackatime_path}']", "Hackatime"
    assert_select "details.site-menu a[href='#{settings_notifications_path}']", "Notifications"
    assert_select "nav > a[href='#{hackatime_path}']", 0
  end

  test "the current page is marked with aria-current" do
    sign_in_as users(:onboarded)
    { projects_path => "Projects", ships_path => "Ships", shop_path => "Shop", dashboard_path => "Dashboard" }.each do |path, label|
      get path
      assert_select "nav[aria-label=Main] a[aria-current=page]", count: 1, text: label
    end
    get hackatime_path
    assert_select "details.site-menu a[aria-current=page]", text: "Hackatime"
    assert_select "details.site-menu summary.is-current", 1
  end

  test "Sign out stays outside the Main landmark and the skip link is still first" do
    sign_in_as users(:onboarded)
    get dashboard_path
    assert_select "nav[aria-label=Main] form", 0
    assert_select ".site-header__account form[action='#{logout_path}']", 1
    assert_select "body > a.skip-link[href='#main']"
    assert_select "main#main"
  end

  test "the brand link is named Battletown once: a decorative logo plus visually hidden text" do
    sign_in_as users(:onboarded)
    get dashboard_path
    assert_select "header a.site-header__brand[href='#{root_path}']" do
      assert_select "img.site-header__logo[alt='']", 1
      assert_select "span.visually-hidden", "Battletown"
    end
    assert_select "header nav", 1
    assert_select "footer nav[aria-label=Legal]", 1
  end

  test "signed-out visitors and people still onboarding get no Main nav" do
    get root_path
    assert_select "nav[aria-label=Main]", 0
    sign_in_as users(:new_user)
    get onboarding_path
    follow_redirect!
    assert_select "nav[aria-label=Main]", 0
    assert_select ".site-header__account form[action='#{logout_path}']", 1
  end
end
