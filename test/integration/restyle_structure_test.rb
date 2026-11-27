require "test_helper"
require_relative "../support/ships_test_support"

# Structure checks for the restyled user pages: one h1, a label for every field, status as words, no inline style.
class RestyleStructureTest < ActionDispatch::IntegrationTest
  include ShipsTestSupport

  setup do
    OmniAuth.config.test_mode = true
    @user = users(:onboarded)
    @user.update_columns(created_at: Time.utc(2026, 11, 1, 12), signed_up_on: Date.new(2026, 11, 1))
    @project = make_project(@user)
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: @user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
  end

  def assert_page_structure
    assert_response :success
    assert_select "h1", 1
    assert_select "[style]", 0
    assert_select "script:not([src]):not([nonce])", 0
    css_select("main input:not([type=hidden]):not([type=submit]):not([type=checkbox]), main select, main textarea").each do |field|
      assert css_select("label[for='#{field['id']}']").any?, "no label for #{field['name']}"
    end
  end

  test "projects pages" do
    [ projects_path, new_project_path, edit_project_path(@project) ].each do |path|
      get path
      assert_page_structure
    end
    get projects_path
    assert_select ".project .badge", text: "Hackatime linked"
    assert_select ".project .badge", text: "Active project"
  end

  test "an empty projects list explains what a project is" do
    @project.destroy
    get projects_path
    assert_page_structure
    assert_select ".empty .empty__text", /A project is the thing you're building/
  end

  test "ships pages show status in words and the requirements checklist" do
    (7..9).each { |day| code(@user, Date.new(2026, 11, day), 3600) }
    get new_project_ship_path(@project)
    assert_page_structure
    assert_select ".ship-checklist li", 4
    assert_select "progress.progress__bar[max][value]", 1
    ship = submit_ship(@project)
    get ships_path
    assert_page_structure
    assert_select ".ship .badge", text: "Waiting for review"
    get ship_path(ship)
    assert_page_structure
  end

  test "hackatime and notification settings" do
    get hackatime_path
    assert_page_structure
    assert_select ".hackatime__status.badge", text: "Not connected"
    assert_select ".hackatime__share li", minimum: 4
    get settings_notifications_path
    assert_page_structure
    assert_select "fieldset legend", 1
    assert_select ".notification-settings__item label[for]", minimum: 1
  end
end
