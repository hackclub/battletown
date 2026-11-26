require "test_helper"
require_relative "../support/ships_test_support"
require_relative "../support/hackatime_helper"

# The short "link your Hackatime project" page the dashboard sends people to: only the project's name and the Hackatime
# project, saved together or not at all. The long edit page keeps every other field.
class ProjectLinkTest < ActionDispatch::IntegrationTest
  include ShipsTestSupport
  include HackatimeHelper

  setup do
    OmniAuth.config.test_mode = true
    @user = users(:onboarded)
    @project = make_project(@user, name: "Space Farm", hackatime: nil)
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: @user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
    stop_fake_hackatime
  end

  def serve_projects(names, status: 200)
    fake = start_fake_hackatime
    fake.on("GET", "/api/v1/authenticated/projects") { |_| [ status, { "projects" => names.map { |name| { "name" => name, "total_seconds" => 60 } } } ] }
    connect_hackatime(@user)
    fake
  end

  test "the page asks for two things only: the project name and the Hackatime project" do
    get link_project_path(@project)
    assert_response :success
    assert_select "h1", "Link your Hackatime projects"
    assert_select "form[action='#{link_project_path(@project)}'] input[name='_method'][value='patch']", 1
    fields = css_select("form input:not([type=hidden])").map { |i| i["name"] }
    assert_equal [ "project[name]", "hackatime_link[hackatime_project]" ], fields
    assert_select "textarea, select", 0
    assert_select "input#project_name[value='Space Farm'][required]"
    assert_select "input#hackatime_project[required][aria-describedby='hackatime-project-hint']"
    assert_select "label[for='project_name']", "Project name"
    assert_select "label[for='hackatime_project']", "Hackatime project"
  end

  test "saving renames the project and links the Hackatime project, then goes back to the dashboard" do
    patch link_project_path(@project), params: { project: { name: "Space Farm 2" }, hackatime_link: { hackatime_project: " space-farm " } }
    assert_redirected_to dashboard_path
    assert_equal "Space Farm 2", @project.reload.name
    link = @project.hackatime_links.sole
    assert_equal "space-farm", link.hackatime_project
    assert_equal "manual", link.link_method
    follow_redirect!
    assert_select ".flash", /Linked space-farm/
  end

  test "a blank name keeps the current one, and a pending question about the same name is answered" do
    suggestion = @project.link_suggestions.create!(hackatime_project: "space-farm")
    patch link_project_path(@project), params: { project: { name: "" }, hackatime_link: { hackatime_project: "space-farm" } }
    assert_redirected_to dashboard_path
    assert_equal "Space Farm", @project.reload.name
    assert_equal "accepted", suggestion.reload.state
  end

  test "nothing is saved when the link is bad: the page shows the problem and keeps what was typed" do
    patch link_project_path(@project), params: { project: { name: "Renamed" }, hackatime_link: { hackatime_project: "" } }
    assert_response :unprocessable_content
    assert_select ".alert--danger", /Add at least one Hackatime project/
    assert_select "input#project_name[value='Renamed']"
    assert_equal "Space Farm", @project.reload.name, "the rename is not kept without the link"
    assert_equal 0, @project.hackatime_links.count

    patch link_project_path(@project), params: { project: { name: "Renamed" }, hackatime_link: { hackatime_project: "bad<name>" } }
    assert_response :unprocessable_content
    assert_select ".alert--danger", /can only use letters/
    assert_includes response.body, "bad&lt;name&gt;", "what was typed is kept, escaped"
    assert_not_includes response.body, "bad<name>"
    assert_equal 0, @project.hackatime_links.count
  end

  test "a bad project name stops the link too" do
    patch link_project_path(@project), params: { project: { name: "x" * 61 }, hackatime_link: { hackatime_project: "space-farm" } }
    assert_response :unprocessable_content
    assert_equal 0, @project.hackatime_links.count
    assert_equal "Space Farm", @project.reload.name
  end

  test "a Hackatime project already linked to another of your projects says which" do
    other = make_project(@user, name: "Other Thing", hackatime: "taken-name")
    patch link_project_path(@project), params: { project: { name: "Space Farm" }, hackatime_link: { hackatime_project: "taken-name" } }
    assert_response :unprocessable_content
    assert_select ".alert--danger", /taken-name is already linked to #{other.name}/
    assert_equal 0, @project.hackatime_links.count
  end

  test "it only ever acts on the signed-in person's own projects" do
    someone = users(:new_user)
    theirs = make_project(someone, name: "Their Project", hackatime: nil)
    get link_project_path(theirs)
    assert_response :not_found
    patch link_project_path(theirs), params: { project: { name: "Stolen" }, hackatime_link: { hackatime_project: "x" } }
    assert_response :not_found
    assert_equal "Their Project", theirs.reload.name
  end

  test "signed-out people are sent home" do
    delete logout_path
    get link_project_path(@project)
    assert_redirected_to root_path
  end

  test "the dashboard's button for a project with no link goes to this page" do
    get dashboard_path
    assert_select "a.stage__cta[href='#{link_project_path(@project)}']", "Link a Hackatime project"
  end

  # --- the searchable multi-select ---

  test "with Hackatime connected the projects they have coded on are a searchable list of checkboxes, minus ones already linked" do
    make_project(@user, name: "Other", hackatime: "already-linked")
    fake = serve_projects([ "space-farm", "Zebra Game", "already-linked", "bad<name>", "alpha" ])
    get link_project_path(@project)
    assert_response :success
    assert_select "[data-controller='multi-select']", 1
    assert_select "details.multi__box:not([open]) summary.multi__summary[aria-labelledby='hackatime-projects-label']", "Choose projects"
    assert_select "input[type=search][aria-controls='hackatime-options'][hidden]", 1, "the search box shows once JavaScript runs"
    names = css_select("input[name='hackatime_link[hackatime_projects][]']").map { |box| box["value"] }
    assert_equal [ "alpha", "space-farm", "Zebra Game" ], names, "sorted, without the linked one and the unlinkable one"
    assert_select "label.multi__option[data-name='zebra game'] input"
    assert_select "input#hackatime_project", 0, "no typed field while the list is there"
    request = fake.requests_for("GET", "/api/v1/authenticated/projects").sole
    assert_equal "true", request.query["include_archived"]
    assert request.query["start_date"].present? && request.query["end_date"].present?
  end

  test "choosing several projects links them all, in one save" do
    serve_projects([ "space-farm", "space-farm-api", "other" ])
    patch link_project_path(@project), params: { project: { name: "Space Farm" }, hackatime_link: { hackatime_projects: [ "space-farm", "space-farm-api" ] } }
    assert_redirected_to dashboard_path
    assert_equal [ "space-farm", "space-farm-api" ], @project.hackatime_links.order(:id).pluck(:hackatime_project)
    follow_redirect!
    assert_select ".flash", /Linked space-farm and space-farm-api/
  end

  test "choosing none says so, keeps the rest of the form and links nothing" do
    serve_projects([ "space-farm" ])
    patch link_project_path(@project), params: { project: { name: "Renamed" }, hackatime_link: { hackatime_projects: [] } }
    assert_response :unprocessable_content
    assert_select ".alert--danger", /Add at least one Hackatime project/
    assert_select "input#project_name[value='Renamed']"
    assert_select "input[name='hackatime_link[hackatime_projects][]']", 1
    assert_equal "Space Farm", @project.reload.name
  end

  test "a failed save keeps what was ticked" do
    serve_projects([ "alpha", "beta" ])
    patch link_project_path(@project), params: { project: { name: "x" * 61 }, hackatime_link: { hackatime_projects: [ "beta" ] } }
    assert_response :unprocessable_content
    assert_select "input#hackatime-option-1[checked]"
    assert_select "input#hackatime-option-0[checked]", 0
    assert_equal 0, @project.hackatime_links.count
  end

  test "if one of the chosen is already linked elsewhere nothing is saved" do
    make_project(@user, name: "Other", hackatime: "taken")
    serve_projects([ "alpha", "taken" ])
    patch link_project_path(@project), params: { project: { name: "Space Farm" }, hackatime_link: { hackatime_projects: [ "alpha", "taken" ] } }
    assert_response :unprocessable_content
    assert_select ".alert--danger", /taken is already linked to Other/
    assert_equal 0, @project.hackatime_links.count
  end

  test "when Hackatime cannot be asked the page falls back to a typed field and says why" do
    serve_projects([], status: 500)
    get link_project_path(@project)
    assert_response :success
    assert_select "[data-controller='multi-select']", 0
    assert_select "input#hackatime_project[name='hackatime_link[hackatime_project]']", 1
    assert_select "#hackatime-project-hint", /couldn't load your Hackatime projects/
  end

  test "with nothing coded yet the page offers the typed field and says to code first" do
    serve_projects([])
    get link_project_path(@project)
    assert_select "input#hackatime_project", 1
    assert_select "#hackatime-project-hint", /didn't find a Hackatime project to pick yet/
  end
end
