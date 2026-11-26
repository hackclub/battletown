require "application_system_test_case"

# Smoke tests in a real browser: what request tests cannot see (assets served, importmap and Stimulus booting,
# a real form post through OmniAuth).
class LandingSystemTest < ApplicationSystemTestCase
  setup do
    OmniAuth.config.test_mode = true
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
  end

  test "the landing page renders and its JavaScript boots" do
    visit root_path

    assert_selector "h1 img[alt='Battletown']"
    assert_selector ".hero__tagline", text: /Build projects,\s+get gear/
    assert_selector "h2", text: "How it works"
    assert_selector "h2", text: "FAQ"
    # Turbo is imported by app/javascript/application.js through the importmap; if a pin 404s it never loads.
    assert_equal "object", page.evaluate_script("typeof window.Turbo")
  end

  test "joining from the landing page opens onboarding, and signing up at the end creates the account" do
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(
      provider: "hack_club", uid: "ident!system-test", extra: { raw_info: {} }
    )

    visit root_path
    assert_no_selector ".hero button.hero__signin" # the hero has no sign-in line any more
    first(".hero a.cta").click

    assert_current_path "/onboarding/age"
    assert_selector ".transition--welcome", text: /Welcome to/
    find(".transition--welcome").click # skipping the splash
    assert_no_selector ".transition"
    click_button "I'm a teen aged 13–18!"
    assert_current_path "/onboarding/prize"
    assert_equal 0, User.where(hca_uid: "ident!system-test").count # nothing is saved before sign-up

    find("label.choice", match: :first).click
    click_button "Continue"
    assert_current_path "/onboarding/project" # straight on: the "others like you" moment plays over this step
    assert_selector ".transition--proof"
    assert_no_selector ".transition", wait: 6 # and fades away by itself
    find("label.toggle", text: "Game").click
    click_button "Continue"
    assert_current_path "/onboarding/schedule"
    assert_selector ".transition--proof" # the "you'll be one of the first" moment plays over this step too
    assert_no_selector ".transition", wait: 6
    find("label.day", text: "Mon").click
    # No address to take a zone from, and a CI browser's own zone (UTC) is not in the list, so the zone picker is open and empty: choose one.
    select "Eastern Time (US & Canada)", from: "Your time zone"
    click_button "Continue"

    assert_current_path "/onboarding/signup"
    click_button "Sign up with Hack Club"
    assert_current_path "/onboarding/account"
    assert_equal 1, User.where(hca_uid: "ident!system-test").count
    assert_equal "game", User.find_by!(hca_uid: "ident!system-test").project_kind
  end
end
