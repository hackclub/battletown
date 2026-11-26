require "test_helper"
require_relative "../support/profiles_helper"
require_relative "../support/bosses_helper"

# The one Settings page: its three sections (#notifications, #hackatime, #profile), the old pages' redirects, and the profile display name.
class SettingsPageTest < ActionDispatch::IntegrationTest
  include ProfilesHelper
  include BossesHelper

  setup { @user = users(:onboarded) }
  teardown { reset_omniauth }

  test "signed-out visitors go home and people who have not finished onboarding go to onboarding, for every settings address" do
    [ [ :get, settings_path ], [ :patch, settings_profile_path ], [ :get, settings_notifications_path ], [ :get, hackatime_path ] ].each do |verb, path|
      send(verb, path)
      assert_redirected_to root_path, path
    end
    sign_in_as users(:new_user)
    [ [ :get, settings_path ], [ :patch, settings_profile_path ], [ :get, settings_notifications_path ], [ :get, hackatime_path ] ].each do |verb, path|
      send(verb, path)
      assert_redirected_to onboarding_path, path
    end
  end

  test "the page is titled Settings and has one h1 and the three sections, each named by its own heading" do
    sign_in_as @user
    get settings_path
    assert_response :success
    assert_select "title", "Settings - Battletown"
    assert_select "h1", count: 1, text: "Settings"
    %w[notifications hackatime profile].each do |id|
      assert_select "section##{id}[aria-labelledby='#{id}-heading']"
      assert_select "h2##{id}-heading", text: id.capitalize
    end
    assert_select "nav[aria-label='On this page'] a[href='#profile']", "Profile"
    assert_select "[style]", 0
    assert_equal "no-store", response.headers["Cache-Control"]
  end

  test "the old addresses lead to the sections of the new page" do
    sign_in_as @user
    get settings_notifications_path
    assert_redirected_to settings_path(anchor: "notifications")
    assert_equal "/settings#notifications", response.location.delete_prefix("http://www.example.com")
    get hackatime_path
    assert_equal "/settings#hackatime", response.location.delete_prefix("http://www.example.com")
  end

  test "saving notification choices still works and goes back to its section" do
    sign_in_as @user
    patch settings_notifications_path, params: { preferences: { ship_approved: "0" } }
    assert_redirected_to settings_path(anchor: "notifications")
    follow_redirect!
    assert_select ".flash--notice", /Saved/
    assert_select "input[name='preferences[ship_approved]'][checked]", 0
  end

  test "the profile section has a display name and the Slack choice, and no visibility switch" do
    sign_in_as @user
    get settings_path
    assert_select "#profile input[name=profile_visible]", 0
    assert_select "#profile label[for=profile_visible]", 0
    assert_select "#profile", text: /Let other players see my profile/, count: 0
    assert_select "#profile", /Other players can see your name, projects and boss damage/
    assert_select "#profile label[for=profile_name]", "Display name"
    assert_select "#profile input[name=profile_name][maxlength='30']"
    assert_select "#profile input[name=profile_name][value]", 0, "no chosen name: the field is empty"
    assert_select "#profile input[name=profile_name][placeholder='#{PublicProfile.handle_for(@user.public_slug)}']", 1
    assert_select "#profile_name_hint, #profile-name-hint", /We never show your real name or email/
    assert_select "#profile input[type=checkbox][name=use_slack][checked]", 1, "Use my Slack name and picture is on by default"
    assert_select "#profile a[href='#{profile_path}']", "View my profile"
    assert_not_includes response.body, "Veteran", "the real name from Hack Club Auth is never offered"
  end

  test "saving a display name keeps it (squished); an empty one goes back to the default" do
    sign_in_as @user
    patch settings_profile_path, params: { profile_name: "  Cool   Kid " }
    assert_redirected_to settings_path(anchor: "profile")
    assert_equal "Cool Kid", @user.reload.profile_name
    follow_redirect!
    assert_select ".flash--notice", /Other players see you as Cool Kid/
    assert_select "#profile input[name=profile_name][value='Cool Kid']", 1
    patch settings_profile_path, params: { profile_name: "" }
    assert_nil @user.reload.profile_name
    follow_redirect!
    assert_select ".flash--notice", /Other players see you as #{PublicProfile.handle_for(@user.public_slug)}/
  end

  test "the address never changes when the name does" do
    sign_in_as @user
    slug = @user.public_slug
    patch settings_profile_path, params: { profile_name: "One" }
    patch settings_profile_path, params: { profile_name: "" }
    assert_equal slug, @user.reload.public_slug
  end

  test "saving with nothing sent keeps the name and does not hide anything" do
    @user.update!(profile_name: "Keeper")
    sign_in_as @user
    patch settings_profile_path
    assert_redirected_to settings_path(anchor: "profile")
    assert_equal "Keeper", @user.reload.profile_name
    get player_path(@user.public_slug)
    assert_response :success
  end

  test "names that break the rules are refused with a message, and nothing is saved" do
    sign_in_as @user
    [ "evil.com", "a@b.co", "<script>", "x" * 31, "https://x.y" ].each do |bad|
      patch settings_profile_path, params: { profile_name: bad }
      assert_response :unprocessable_content, bad
      assert_select ".projects-errors", /Display name/
      assert_select "#profile_name[aria-invalid=true]"
      assert_nil @user.reload.profile_name, bad
    end
  end

  test "a refused name is shown at the field and in an error summary that takes focus, and the field keeps what was typed" do
    sign_in_as @user
    patch settings_profile_path, params: { profile_name: "evil.com" }
    assert_response :unprocessable_content
    assert_select "#profile-errors[tabindex='-1'][data-controller='focus-errors'] [role=alert]", 1
    assert_select "#profile_name[aria-describedby='profile-name-error profile-name-hint'][value='evil.com']"
    assert_select "p#profile-name-error.field__error", /web address/
  end

  test "a team-sounding name is refused too" do
    sign_in_as @user
    patch settings_profile_path, params: { profile_name: "Hack Club Staff" }
    assert_response :unprocessable_content
    assert_select ".projects-errors", /Display name/
    assert_nil @user.reload.profile_name
  end

  test "saving drops the boss stage's cached snapshot at once, so a new name shows on the stage" do
    boss = make_boss(starts_on: friday_on_or_before(Time.current.utc.to_date), hp_seconds: 100 * HOUR)
    dropped = []
    sign_in_as @user
    stub_method(Bosses::Fighters, :forget_for, ->(given, **) { dropped << given.id }) do
      patch settings_profile_path, params: { profile_name: "Renamed" }
      assert_equal [ boss.id ], dropped.uniq
    end
  end

  test "a display name wins over the Slack name, and turning the Slack choice off keeps the typed name" do
    SlackProfile.create!(user_id: @user.id, display_name: "Slacky", use_name: true, use_picture: true)
    sign_in_as @user
    assert_equal "Slacky", @user.reload.public_name
    patch settings_profile_path, params: { profile_name: "Bob", use_slack: "1" }
    assert_equal "Bob", @user.reload.public_name
    assert SlackProfile.find_by!(user_id: @user.id).use_name, "typing a name does not turn the Slack choice off"
    patch settings_profile_path, params: { profile_name: "Bob", use_slack: "0" }
    assert_equal "Bob", @user.reload.public_name
    assert_not SlackProfiles::Choice.use_slack?(@user)
    assert_nil SlackProfile.find_by!(user_id: @user.id).display_name, "the Slack copy is deleted"
    patch settings_profile_path, params: { profile_name: "" }
    assert_equal PublicProfile.handle_for(@user.public_slug), @user.reload.public_name, "Slack off and no name: the generated handle"
  end

  test "the Slack choice is on until it is turned off, with no row at all" do
    SlackProfile.where(user_id: @user.id).delete_all
    assert SlackProfiles::Choice.use_slack?(@user)
    sign_in_as @user
    get settings_path
    assert_select "#profile input[type=checkbox][name=use_slack][checked]", 1
  end

  test "odd parameters cannot break it" do
    sign_in_as @user
    patch settings_profile_path, params: { profile_name: [ "x" ] }
    assert_response :unprocessable_content
    patch settings_profile_path, params: { profile_name: { a: "b" } }
    assert_includes [ 302, 303, 422 ], response.status
    slug = @user.public_slug
    patch settings_profile_path, params: { user_id: users(:new_user).id, public_slug: "hijacked123", profile_visible: "0", id: users(:new_user).id }
    assert_equal users(:new_user).reload.public_slug, "fixturenew1"
    assert_equal slug, @user.reload.public_slug
  end

  test "the profile section never shows anyone else's data" do
    other = make_player("someoneelse", name: "Zed")
    sign_in_as @user
    get settings_path
    assert_not_includes response.body, other.profile_name
    assert_not_includes response.body, other.public_slug
  end
end
