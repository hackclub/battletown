require "test_helper"

class ProjectsTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    @user = users(:onboarded)
    @mine = Project.create!(user: @user, name: "Space Farm", kind: "game", idea: "Cows in space")
    @theirs = Project.create!(user: users(:new_user), name: "Secret Plans", kind: "tool", idea: "PRIVATE-IDEA-XYZ")
    @theirs_link = @theirs.hackatime_links.create!(user_id: users(:new_user).id, hackatime_project: "their-hackatime", link_method: "manual")
    @theirs_suggestion = @theirs.link_suggestions.create!(hackatime_project: "their-other")
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

  def project_params(attrs = {}) = { project: { name: "New thing", kind: "app", idea: "An idea" }.merge(attrs) }

  # --- access ---

  test "signed-out visitors are sent home from every projects route" do
    get projects_path
    assert_redirected_to root_path
    get new_project_path
    assert_redirected_to root_path
    post projects_path, params: project_params
    assert_redirected_to root_path
    patch activate_project_path(@mine)
    assert_redirected_to root_path
    assert_equal 2, Project.count
  end

  test "users who have not finished onboarding are sent to onboarding" do
    sign_in_as users(:new_user)
    get projects_path
    assert_redirected_to onboarding_path
    post projects_path, params: project_params
    assert_redirected_to onboarding_path
    assert_equal 1, users(:new_user).projects.count
  end

  test "the header links to Projects for onboarded users only" do
    sign_in_as @user
    get dashboard_path
    assert_select "nav[aria-label=Main] a[href='#{projects_path}']", "Projects"
    delete logout_path
    get root_path
    assert_select "a[href='#{projects_path}']", 0
  end

  test "/projects/:id has no page of its own and the catch-all does not swallow it" do
    sign_in_as @user
    get "/projects/#{@mine.id}"
    assert_response :not_found
  end

  # --- one user can never reach another's project ---

  test "another user's project is a 404 for every action and nothing changes" do
    sign_in_as @user
    before = [ @theirs.reload.attributes, @theirs_link.reload.attributes, @theirs_suggestion.reload.attributes ]

    get edit_project_path(@theirs)
    assert_response :not_found
    patch project_path(@theirs), params: project_params(name: "Hijacked")
    assert_response :not_found
    patch activate_project_path(@theirs)
    assert_response :not_found
    patch archive_project_path(@theirs)
    assert_response :not_found
    patch unarchive_project_path(@theirs)
    assert_response :not_found
    post project_hackatime_links_path(@theirs), params: { hackatime_link: { hackatime_project: "mine-now" } }
    assert_response :not_found
    delete project_hackatime_link_path(@theirs, @theirs_link)
    assert_response :not_found
    patch accept_project_link_suggestion_path(@theirs, @theirs_suggestion)
    assert_response :not_found
    patch decline_project_link_suggestion_path(@theirs, @theirs_suggestion)
    assert_response :not_found
    delete project_path(@theirs)
    assert_response :not_found

    assert_equal before, [ @theirs.reload.attributes, @theirs_link.reload.attributes, @theirs_suggestion.reload.attributes ]
    assert_equal 0, HackatimeLink.where(hackatime_project: "mine-now").count
  end

  test "ids from another project cannot be smuggled in through your own project's URL" do
    sign_in_as @user
    delete project_hackatime_link_path(@mine, @theirs_link)
    assert_response :not_found
    patch accept_project_link_suggestion_path(@mine, @theirs_suggestion)
    assert_response :not_found
    assert HackatimeLink.exists?(@theirs_link.id)
    assert @theirs_suggestion.reload.pending?
  end

  test "the list never shows another user's projects or suggestions" do
    sign_in_as @user
    get projects_path
    assert_response :success
    assert_select ".project__name", "Space Farm"
    assert_not_includes response.body, "Secret Plans"
    assert_not_includes response.body, "PRIVATE-IDEA-XYZ"
    assert_not_includes response.body, "their-other"
  end

  # --- create / edit ---

  test "creating a project: the first one is active, defaults to nothing else" do
    sign_in_as users(:new_user).tap { |u| u.update!(onboarded_at: Time.current, onboarding_step: 4) }
    Project.where(user_id: users(:new_user).id).destroy_all
    post projects_path, params: project_params(repo_url: "HTTPS://www.github.com/Octo/Cat.git", demo_url: "https://example.com/play")
    assert_redirected_to projects_path
    project = Project.where(user_id: users(:new_user).id).sole
    assert project.active?
    assert_equal "https://github.com/octo/cat", project.repo_url
    assert_equal "https://example.com/play", project.demo_url
    assert_equal "active", project.status
  end

  test "a second project does not steal the active flag" do
    sign_in_as @user
    post projects_path, params: project_params
    assert_redirected_to projects_path
    assert_equal [ @mine.id ], @user.projects.where(active: true).pluck(:id)
    assert_equal 2, @user.projects.count
  end

  test "an invalid project keeps the form markup bare: no field_with_errors wrapper, the control is aria-invalid" do
    sign_in_as @user
    post projects_path, params: project_params(name: "")
    assert_response :unprocessable_entity
    assert_select ".field_with_errors", 0
    assert_select "input#project_name[aria-invalid=true]", 1
    assert_select "label[for=project_name][aria-invalid]", 0
  end

  test "status, active, guide_key and user_id cannot be set from the form" do
    sign_in_as @user
    post projects_path, params: project_params(status: "archived", active: "1", guide_key: "sd", user_id: users(:new_user).id)
    created = @user.projects.find_by!(name: "New thing")
    assert created.status_active?
    assert_not created.active?
    assert_nil created.guide_key
    assert_equal @user.id, created.user_id
    patch project_path(@mine), params: project_params(name: "Renamed", status: "archived", active: "0", guide_key: "sd")
    assert_equal [ "Renamed", "active", true, nil ], @mine.reload.values_at(:name, :status, :active, :guide_key)
  end

  test "invalid input re-renders with friendly messages and saves nothing" do
    sign_in_as @user
    assert_no_difference "Project.count" do
      post projects_path, params: project_params(name: "", kind: "spaceship", idea: "x" * 501, repo_url: "https://gitlab.com/a/b", demo_url: "http://nope.example")
    end
    assert_response :unprocessable_content
    assert_select "[role=alert]", /Name/
    assert_select "[role=alert]", /GitHub link should look like https:\/\/github.com\/your-name\/your-repo/
    assert_select "[role=alert]", /Demo link should be a full link starting with https/
    assert_select "[role=alert]", /Idea is too long/
  end

  test "a malformed project param is rejected cleanly" do
    sign_in_as @user
    post projects_path, params: { project: "abc" }
    assert_response :unprocessable_content
  end

  test "editing and updating" do
    sign_in_as @user
    get edit_project_path(@mine)
    assert_response :success
    assert_select "input[name='project[name]'][value='Space Farm']"
    patch project_path(@mine), params: project_params(name: "Moon Farm", idea: "")
    assert_redirected_to projects_path
    assert_equal "Moon Farm", @mine.reload.name
    assert_nil @mine.idea
    patch project_path(@mine), params: project_params(name: "")
    assert_response :unprocessable_content
    assert_equal "Moon Farm", @mine.reload.name
    assert_select "h1", "Edit Moon Farm"
  end

  test "the 10 project limit is enforced and the add button disappears" do
    sign_in_as @user
    (Project::MAX_PER_USER - 1).times { |i| Project.create!(user: @user, name: "P#{i}") }
    get projects_path
    assert_select "a[href='#{new_project_path}']", 0
    assert_no_difference "Project.count" do
      post projects_path, params: project_params
    end
    assert_response :unprocessable_content
    assert_select "[role=alert]", /up to 10 projects/
    @user.projects.where.not(id: @mine.id).first.discard!
    assert_difference "Project.count", 1 do
      post projects_path, params: project_params
    end
  end

  # --- active, archive, delete ---

  test "set active switches exactly one project" do
    other = Project.create!(user: @user, name: "Website")
    sign_in_as @user
    patch activate_project_path(other)
    assert_redirected_to projects_path
    assert_equal [ other.id ], @user.projects.where(active: true).pluck(:id)
    get projects_path
    assert_select ".badge--active", 1
    assert_select ".project--active .project__name", "Website"
  end

  test "archive, unarchive and archived projects cannot be made active" do
    other = Project.create!(user: @user, name: "Website")
    sign_in_as @user
    patch archive_project_path(@mine)
    assert_redirected_to projects_path
    assert @mine.reload.status_archived?
    assert other.reload.active?, "another live project takes over as active"

    patch activate_project_path(@mine)
    assert_redirected_to projects_path
    assert_not @mine.reload.active?
    follow_redirect!
    assert_select ".flash--alert", /Unarchive/

    get projects_path
    assert_select "h2", "Archived"
    patch unarchive_project_path(@mine)
    assert @mine.reload.status_active?
  end

  test "deleting removes the project with its links and suggestions" do
    @mine.hackatime_links.create!(user_id: @user.id, hackatime_project: "space-farm", link_method: "manual")
    @mine.link_suggestions.create!(hackatime_project: "other")
    sign_in_as @user
    delete project_path(@mine)
    assert_redirected_to projects_path
    assert_not Project.exists?(@mine.id)
    assert_equal 0, HackatimeLink.where(project_id: @mine.id).count
    assert_equal 0, LinkSuggestion.where(project_id: @mine.id).count
    assert Project.exists?(@theirs.id)
  end

  # --- Hackatime links ---

  test "linking and unlinking a Hackatime project by exact name" do
    sign_in_as @user
    post project_hackatime_links_path(@mine), params: { hackatime_link: { hackatime_project: "  space-farm  " } }
    assert_redirected_to edit_project_path(@mine)
    link = @mine.hackatime_links.sole
    assert_equal [ "space-farm", "manual" ], [ link.hackatime_project, link.link_method ]
    follow_redirect!
    assert_select ".links__name", "space-farm"

    delete project_hackatime_link_path(@mine, link)
    assert_redirected_to edit_project_path(@mine)
    assert_equal 0, @mine.hackatime_links.count
    assert @mine.link_suggestions.find_by!(hackatime_project: "space-farm").declined?, "unlinking is remembered so it is not auto-linked back"
  end

  test "link errors are friendly: blank, bad characters, too long, already linked elsewhere, limit" do
    other = Project.create!(user: @user, name: "Website")
    other.hackatime_links.create!(user_id: @user.id, hackatime_project: "taken", link_method: "manual")
    sign_in_as @user
    [ "", "<script>alert(1)</script>", "x" * 121 ].each do |bad|
      post project_hackatime_links_path(@mine), params: { hackatime_link: { hackatime_project: bad } }
      assert_redirected_to edit_project_path(@mine)
      follow_redirect!
      assert_select ".flash--alert", /Type the name|Couldn't link/
    end
    post project_hackatime_links_path(@mine), params: { hackatime_link: { hackatime_project: "taken" } }
    follow_redirect!
    assert_select ".flash--alert", /taken is already linked to Website\. Unlink it there first/
    assert_equal 0, @mine.hackatime_links.count
    post project_hackatime_links_path(@mine), params: { hackatime_link: "oops" }
    assert_redirected_to edit_project_path(@mine)
  end

  test "typing a name that has a pending question answers it" do
    suggestion = @mine.link_suggestions.create!(hackatime_project: "space-farm-dev")
    sign_in_as @user
    post project_hackatime_links_path(@mine), params: { hackatime_link: { hackatime_project: "space-farm-dev" } }
    assert suggestion.reload.accepted?
  end

  # --- suggestions ---

  test "accepting a suggestion links it as confirmed; declining is remembered" do
    yes = @mine.link_suggestions.create!(hackatime_project: "space-farm-dev")
    no = @mine.link_suggestions.create!(hackatime_project: "space-farm-old")
    sign_in_as @user
    get projects_path
    assert_select ".suggestion", 2
    assert_select ".suggestion__text", /space-farm-dev/

    patch accept_project_link_suggestion_path(@mine, yes)
    assert_redirected_to projects_path
    assert_equal "confirmed", @mine.hackatime_links.find_by!(hackatime_project: "space-farm-dev").link_method
    patch decline_project_link_suggestion_path(@mine, no)
    assert no.reload.declined?
    assert_nil @mine.hackatime_links.find_by(hackatime_project: "space-farm-old")

    patch accept_project_link_suggestion_path(@mine, no)
    follow_redirect!
    assert_select ".flash--notice", /already answered/
    assert_equal 1, @mine.hackatime_links.count
    get projects_path
    assert_select ".suggestion", 0
  end

  test "accepting a suggestion for a name linked elsewhere in the meantime shows a friendly error" do
    other = Project.create!(user: @user, name: "Website")
    suggestion = @mine.link_suggestions.create!(hackatime_project: "shared")
    other.hackatime_links.create!(user_id: @user.id, hackatime_project: "shared", link_method: "manual")
    sign_in_as @user
    patch accept_project_link_suggestion_path(@mine, suggestion)
    follow_redirect!
    assert_select ".flash--alert", /already linked/
    assert suggestion.reload.pending?
  end

  # --- onboarding ---

  def onboarding_step(name, params = {}) = patch(onboarding_step_path(name), params: { user: params })

  test "the onboarding project step creates the first project and keeps the user columns" do
    user = users(:new_user)
    Project.where(user_id: user.id).destroy_all
    sign_in_as user
    onboarding_step("prize", prize_key: "tshirt")
    onboarding_step("project", project_kind: "game", project_idea: "A farming game. Cows included.")
    assert_redirected_to onboarding_step_path("schedule")

    project = Project.where(user_id: user.id).sole
    assert_equal [ "A farming game", "game", "A farming game. Cows included.", true ], [ project.name, project.kind, project.idea, project.active? ]
    assert_equal [ "game", "A farming game. Cows included." ], [ user.reload.project_kind, user.project_idea ]
  end

  test "going back through the project step updates the same project and keeps a custom name" do
    user = users(:new_user)
    Project.where(user_id: user.id).destroy_all
    sign_in_as user
    onboarding_step("prize", prize_key: "tshirt")
    onboarding_step("project", project_kind: "game", project_idea: "A farming game")
    onboarding_step("project", project_kind: "app", project_idea: "A budgeting app")
    assert_equal [ "A budgeting app", "app" ], Project.where(user_id: user.id).sole.values_at(:name, :kind)

    Project.where(user_id: user.id).sole.update!(name: "Budget Buddy")
    onboarding_step("project", project_kind: "tool")
    assert_equal [ "Budget Buddy", "tool", 1 ], [ Project.where(user_id: user.id).sole.name, Project.where(user_id: user.id).sole.kind, Project.where(user_id: user.id).count ]
  end

  test "a kind alone gets a default name; invalid onboarding input creates no project" do
    user = users(:new_user)
    Project.where(user_id: user.id).destroy_all
    sign_in_as user
    onboarding_step("prize", prize_key: "tshirt")
    onboarding_step("project", project_kind: "spaceship")
    assert_response :unprocessable_content
    onboarding_step("project", project_kind: "game", project_idea: "x" * 501)
    assert_response :unprocessable_content
    assert_equal 0, Project.where(user_id: user.id).count
    onboarding_step("project", project_kind: "hardware")
    assert_equal "My hardware project", Project.where(user_id: user.id).sole.name
  end

  test "an onboarded user with projects revisiting the step updates their first project, not a new one" do
    sign_in_as @user
    Project.create!(user: @user, name: "Second")
    onboarding_step("project", project_kind: "website", project_idea: "A portfolio")
    assert_equal 2, @user.projects.count
    assert_equal "website", @mine.reload.kind
  end

  test "project params are filtered from the request log" do
    io = StringIO.new
    old = ActionController::Base.logger
    ActionController::Base.logger = ActiveSupport::Logger.new(io)
    sign_in_as @user
    post projects_path, params: project_params(name: "LOGGED-NAME-123", idea: "LOGGED-IDEA-123", repo_url: "https://github.com/logged/repo-123", demo_url: "https://logged-demo-123.example.com")
    post project_hackatime_links_path(@mine), params: { hackatime_link: { hackatime_project: "logged-hackatime-123" } }
    assert_includes io.string, "Parameters:"
    %w[LOGGED-NAME-123 LOGGED-IDEA-123 repo-123 logged-demo-123 logged-hackatime-123].each { |secret| assert_not_includes io.string, secret }
  ensure
    ActionController::Base.logger = old
  end
end
