require "test_helper"
require_relative "../support/hackatime_helper"
require_relative "../support/profiles_helper"

# The last onboarding step says plainly that every player has a profile. There is no checkbox: nothing to opt in to and nothing to opt out of.
class OnboardingProfileNoteTest < ActionDispatch::IntegrationTest
  include HackatimeHelper
  include ProfilesHelper

  teardown { reset_omniauth }

  def at_account_step(user)
    user.update!(onboarding_step: 5)
    connect_hackatime(user)
    sign_in_as user
  end

  test "the account step has no profile checkbox, only a plain sentence about what other players see" do
    user = users(:new_user)
    at_account_step(user)
    get onboarding_step_path("account")
    assert_response :success
    assert_select "#profile-check input", 0
    assert_select "#profile-check", /Every player has a profile page/
    assert_select "#profile-check", /Other players can see your name, projects and boss damage/
    assert_select "#profile-check", /never your email or your real name/
    assert_select "#profile-check strong", PublicProfile.handle_for(user.public_slug)
    assert_not_includes response.body, "Newbie", "the real name from Hack Club Auth is never offered as a profile name"
    assert_select "[style]", 0
  end

  test "finishing the step needs nothing about a profile, and the player already has an address and no display name" do
    user = users(:new_user)
    at_account_step(user)
    patch onboarding_step_path("account"), params: { user: { referral_source: "" } }
    assert_redirected_to onboarding_step_path("celebrate")
    user.reload
    assert_match(/\A[a-z0-9]{10,12}\z/, user.public_slug)
    assert_nil user.profile_name
  end

  test "a visibility field sent anyway changes nothing, and neither does an address or a name" do
    user = users(:new_user)
    slug = user.public_slug
    at_account_step(user)
    patch onboarding_step_path("account"), params: { user: { profile_visible: "0", public_slug: "hijacked123", profile_name: "x@y.z" } }
    assert_response :redirect
    user.reload
    assert_equal slug, user.public_slug
    assert_nil user.profile_name
  end

  test "someone editing the step later sees the same sentence" do
    sign_in_as users(:onboarded)
    get onboarding_step_path("account")
    assert_select "#profile-check input", 0
    assert_select "#profile-check", /Other players can see your name, projects and boss damage/
  end
end
