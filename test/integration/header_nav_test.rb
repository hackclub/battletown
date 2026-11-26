require "test_helper"
require_relative "../support/profiles_helper"

# The signed-in header: one labelled landmark with four plain links (Dashboard, Profile, Armoury, Settings), no menus and no
# JavaScript, and the current page marked for screen readers.
class HeaderNavTest < ActionDispatch::IntegrationTest
  include ProfilesHelper

  teardown { reset_omniauth }

  def nav_links = css_select("nav[aria-label=Main] > a").map { |link| [ link.text.strip, link["href"] ] }

  test "onboarded people get exactly Dashboard, Profile, Armoury and Settings, in that order, inside a labelled Main landmark" do
    sign_in_as users(:onboarded)
    get dashboard_path
    assert_select "nav[aria-label=Main]", 1
    assert_equal [ [ "Dashboard", dashboard_path ], [ "Profile", profile_path ], [ "Armoury", shop_path ], [ "Settings", settings_path ] ], nav_links
    assert_select "nav[aria-label=Main] > *", 4, "nothing in the nav but the four links"
  end

  test "there is no dropdown, no Projects link, no Ships link and no old Shop label in the header" do
    sign_in_as users(:onboarded)
    get dashboard_path
    assert_select "header details, header summary, .site-menu, .site-menu__panel", 0
    assert_select "header a[href='#{projects_path}']", 0
    assert_select "header a[href='#{hackatime_path}'], header a[href='#{settings_notifications_path}']", 0
    assert_select "header nav a", text: /\A\s*(Shop|Ships|Projects|Hackatime|Notifications)\s*\z/, count: 0
    assert_select "nav[aria-label=Main] a[href='#{settings_path}']", text: "Settings", count: 1
  end

  test "the current page is marked with aria-current, and only one link at a time" do
    sign_in_as users(:onboarded)
    { dashboard_path => "Dashboard", player_path(users(:onboarded).public_slug) => "Profile", shop_path => "Armoury", settings_path => "Settings" }.each do |path, label|
      get path
      assert_response :success, path
      assert_select "nav[aria-label=Main] a[aria-current=page]", count: 1, text: label
      assert_select "nav[aria-label=Main] a.is-current", count: 1, text: label
    end
  end

  test "Profile is current on your own player page but not on someone else's, and Settings on the old Hackatime and notification addresses once they redirect" do
    owner = make_player("navplayer", name: "Navy")
    me = users(:onboarded)
    me.update!(profile_name: "Me")
    sign_in_as me
    get player_path(owner.public_slug)
    assert_response :success
    assert_select "nav[aria-label=Main] a[aria-current=page]", 0
    assert_select "nav[aria-label=Main] a.is-current", 0

    get player_path(me.public_slug)
    assert_response :success
    assert_select "nav[aria-label=Main] a[aria-current=page]", count: 1, text: "Profile"

    get hackatime_path
    assert_redirected_to settings_path(anchor: "hackatime")
    follow_redirect!
    assert_select "nav[aria-label=Main] a[aria-current=page]", count: 1, text: "Settings"

    get settings_notifications_path
    assert_redirected_to settings_path(anchor: "notifications")
  end

  test "pages that are not in the nav (projects, orders) mark no link as current" do
    sign_in_as users(:onboarded)
    get projects_path
    assert_response :success
    assert_select "nav[aria-label=Main] a[aria-current]", 0
    assert_select "nav[aria-label=Main] a", 4
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

    get settings_path
    assert_select "footer nav[aria-label=Legal]", 1
    assert_select "footer nav[aria-label=Legal] a[href='https://hackclub.com/privacy-and-terms/']", 1
  end

  test "signed-out visitors and people still onboarding get no Main nav" do
    get root_path
    assert_select "nav[aria-label=Main]", 0
    assert_select "header details, header summary", 0
    sign_in_as users(:new_user)
    get onboarding_path
    follow_redirect!
    assert_select "nav[aria-label=Main], header details, header summary", 0
    assert_select ".site-header__account form[action='#{logout_path}']", 1
  end
end
