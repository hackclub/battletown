require "test_helper"
require_relative "../support/ships_test_support"

class ShipsTest < ActionDispatch::IntegrationTest
  include ShipsTestSupport

  D = ->(day) { Date.new(2026, 11, day) }
  HOURS_NOW = Time.utc(2026, 11, 10, 12)

  setup do
    OmniAuth.config.test_mode = true
    @detailed = Rails.application.env_config["action_dispatch.show_detailed_exceptions"]
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = false
    @user = users(:onboarded)
    @user.update_columns(created_at: Time.utc(2026, 11, 1, 12))
    @project = make_project(@user)
    @other_user = users(:new_user)
    @other_user.update_columns(onboarded_at: Time.utc(2026, 11, 2), onboarding_step: 4)
    @theirs = make_project(@other_user, name: "Secret Plans", hackatime: "secret-hackatime")
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = @detailed
  end

  def sign_in_as(user)
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
  end

  def three_hours = (7..9).each { |day| code(@user, D[day], HOUR) }

  def ship_params(**extra) = { ship: ship_attrs(**extra), ship_action: "submit" }

  # --- access ---

  test "signed-out visitors are sent home from every ships route" do
    ship = (three_hours && submit_ship(@project))
    get ships_path
    assert_redirected_to root_path
    get new_project_ship_path(@project)
    assert_redirected_to root_path
    post project_ships_path(@project), params: ship_params
    assert_redirected_to root_path
    get ship_path(ship)
    assert_redirected_to root_path
    patch withdraw_ship_path(ship)
    assert_redirected_to root_path
    assert_equal "submitted", ship.reload.status
  end

  test "users who have not finished onboarding are sent to onboarding" do
    sign_in_as users(:new_user).tap { |user| user.update_columns(onboarded_at: nil) }
    get ships_path
    assert_redirected_to onboarding_path
  end

  test "ships routes are not swallowed by the referral catch-all" do
    sign_in_as @user
    get "/ships"
    assert_response :success
    assert_select "h1", "Your ships"
  end

  test "someone else's project and ships are a 404" do
    three_hours
    submit_ship(@project)
    code(@other_user, D[9], HOUR, hackatime: "secret-hackatime")
    theirs = submit_ship(@theirs, description: "PRIVATE-DESCRIPTION-XYZ")
    sign_in_as @user

    get new_project_ship_path(@theirs)
    assert_response :not_found
    post project_ships_path(@theirs), params: ship_params
    assert_response :not_found
    [ ship_path(theirs), edit_ship_path(theirs) ].each do |path|
      get path
      assert_response :not_found
      assert_not_includes response.body, "PRIVATE-DESCRIPTION-XYZ"
    end
    patch ship_path(theirs), params: ship_params
    assert_response :not_found
    patch withdraw_ship_path(theirs)
    assert_response :not_found
    assert_equal "submitted", theirs.reload.status

    get ships_path
    assert_select ".ship", 1
    assert_not_includes response.body, "Secret Plans"
  end

  # --- the form ---

  test "a project card has a Ship action" do
    sign_in_as @user
    get projects_path
    assert_select "a[href=?]", new_project_ship_path(@project), text: "Ship"
    @project.archive!
    get projects_path
    assert_select "a[href=?]", new_project_ship_path(@project), 0
  end

  test "the header links to Ships for onboarded users" do
    sign_in_as @user
    get dashboard_path
    assert_select "nav[aria-label=Account] a[href='#{ships_path}']", "Ships"
  end

  test "a project with no linked Hackatime project asks to link one and shows no form" do
    loose = make_project(@user, name: "Loose", hackatime: nil)
    sign_in_as @user
    get new_project_ship_path(loose)
    assert_response :success
    assert_select "a[href=?]", edit_project_path(loose), text: /Link a Hackatime project/
    assert_select "form.ship-form", 0
    assert_select "details.ship-rules", 1
  end

  test "a linked project with too few hours explains the minimum and shows no form" do
    code(@user, D[9], 1800)
    sign_in_as @user
    get new_project_ship_path(@project)
    assert_response :success
    assert_select ".ship-window", text: /0\.5 hours/
    assert_select ".ship-window", text: /at least 1 hour/
    assert_select "form.ship-form", 0
  end

  test "a linked project with no hours says to keep coding" do
    sign_in_as @user
    get new_project_ship_path(@project)
    assert_select ".ship-window", text: /Keep coding/
    assert_select "form.ship-form", 0
  end

  test "the form says how many hours are ready, explains the rule and defaults the links from the project" do
    @project.update!(repo_url: REPO, demo_url: "https://play.example.com/farm")
    three_hours
    sign_in_as @user
    get new_project_ship_path(@project)
    assert_response :success
    assert_select ".ship-window h2", text: /You've coded 3 hours on this project so far/
    assert_select ".ship-window", text: /Nov 7 to Nov 9/
    assert_select "details.ship-rules li", text: /since your last ship/
    assert_select "textarea[name='ship[description]'][required]"
    assert_select "input[name='ship[repo_url]'][required][value=?]", REPO
    assert_select "input[name='ship[demo_url]'][value=?]", "https://play.example.com/farm"
    assert_select "button[name=ship_action][value=submit]", "Submit ship"
  end

  test "after a ship the form says hours since the last ship" do
    three_hours
    first = submit_ship(@project)
    first.update_columns(status: "approved", approved_seconds: 3 * HOUR, reviewed_at: Time.current)
    code(@user, D[10], 2 * HOUR)
    sign_in_as @user
    get new_project_ship_path(@project)
    assert_select ".ship-window h2", text: /You've coded 2 hours on this project since your last ship/
  end

  test "past the deflation threshold the form warns about the lower rate" do
    (1..3).each { |day| code(@user, D[day], 3 * HOUR) }
    sign_in_as @user
    get new_project_ship_path(@project)
    assert_select "details.ship-rules li", text: /Hours past 6 in one ship earn 8 coins an hour instead of 10/
  end

  test "an unverified user is told they can ship and that coins unlock after verifying, with the verify link" do
    three_hours
    sign_in_as @user
    get new_project_ship_path(@project)
    assert_select ".ship-note", text: /verify your identity with Hack Club/
    assert_select ".ship-note a[href='https://auth.hackclub.com']"
    @user.update_columns(verification_status: "verified")
    get new_project_ship_path(@project)
    assert_select ".ship-note", 0
  end

  # --- submitting ---

  test "submitting creates a waiting ship and the project then cannot open a second one" do
    three_hours
    sign_in_as @user
    assert_difference -> { Ship.count }, 1 do
      post project_ships_path(@project), params: ship_params
    end
    ship = Ship.last
    assert_redirected_to ship_path(ship)
    assert_equal "submitted", ship.status
    assert_equal 3 * HOUR, ship.coded_seconds
    follow_redirect!
    assert_select ".badge", "Waiting for review"
    assert_select "button", text: "Withdraw ship"
    assert_select ".flash", text: /submitted/

    get new_project_ship_path(@project)
    assert_redirected_to ship_path(ship)
    assert_no_difference -> { Ship.count } do
      post project_ships_path(@project), params: ship_params
    end
    assert_redirected_to ship_path(ship)
  end

  test "a form with problems is sent back with friendly messages and what was typed" do
    three_hours
    sign_in_as @user
    assert_no_difference -> { Ship.count } do
      post project_ships_path(@project), params: { ship: { description: "", repo_url: "https://example.com/not-github", demo_url: "http://insecure.example" }, ship_action: "submit" }
    end
    assert_response :unprocessable_content
    assert_select ".projects-errors li", text: /GitHub link should look like/
    assert_select ".projects-errors li", text: /Demo link should be a full link/
    assert_select ".projects-errors li", text: /Description needs a few words/
    assert_select "input[name='ship[repo_url]'][value=?]", "https://example.com/not-github"
  end

  test "submitting a project that cannot be shipped is explained, not an error page" do
    code(@user, D[9], 600)
    sign_in_as @user
    post project_ships_path(@project), params: ship_params
    assert_response :unprocessable_content
    assert_select ".ship-window", text: /at least 1 hour/
    assert_equal 0, Ship.count
  end

  test "a draft can be saved, continued and submitted" do
    three_hours
    sign_in_as @user
    post project_ships_path(@project), params: { ship: { description: "", repo_url: "" }, ship_action: "draft" }
    draft = Ship.last
    assert_equal "draft", draft.status
    assert_redirected_to ship_path(draft)
    follow_redirect!
    assert_select "a[href=?]", edit_ship_path(draft), text: "Continue draft"

    get edit_ship_path(draft)
    assert_response :success
    patch ship_path(draft), params: ship_params(description: "Now with cows")
    assert_redirected_to ship_path(draft)
    assert_equal "submitted", draft.reload.status
    assert_equal "Now with cows", draft.description

    get edit_ship_path(draft)
    assert_redirected_to ship_path(draft)
  end

  # --- withdraw, rejection, approval ---

  test "withdrawing frees the hours for the next ship" do
    three_hours
    ship = submit_ship(@project)
    sign_in_as @user
    patch withdraw_ship_path(ship)
    assert_redirected_to ships_path
    assert_equal "withdrawn", ship.reload.status
    get new_project_ship_path(@project)
    assert_select ".ship-window h2", text: /3 hours/
    patch withdraw_ship_path(ship)
    assert_redirected_to ship_path(ship)
  end

  test "a rejected ship shows the reviewer's reason and a fix-and-ship-again path that keeps what was written" do
    three_hours
    ship = submit_ship(@project, description: "First try")
    Ships::Reject.call(ship: ship, reviewer: @other_user, reason: "The demo link does not open: please check it")
    sign_in_as @user

    get ships_path
    assert_select ".ship__result--rejected", text: /The demo link does not open: please check it/
    get ship_path(ship)
    assert_select ".ship-result--rejected", text: /The demo link does not open: please check it/
    assert_select "a[href=?]", new_project_ship_path(@project, from: ship.id), text: "Fix and ship again"

    get new_project_ship_path(@project, from: ship.id)
    assert_select "textarea[name='ship[description]']", text: /First try/
    post project_ships_path(@project), params: ship_params(description: "Fixed it")
    again = Ship.order(:id).last
    assert_not_equal ship.id, again.id
    assert_equal ship.window_dates, again.window_dates
  end

  test "an approved ship shows the breakdown read from the ledger" do
    three_hours
    ship = submit_ship(@project)
    travel_to(HOURS_NOW) { Ships::Approve.call(ship: ship, reviewer: @other_user, approved_seconds: 2 * HOUR, now: Time.current) }
    sign_in_as @user
    get ship_path(ship)
    assert_select ".ship-result", text: /2 hours approved/
    assert_select ".ship-result__line", text: /20 base coins \+ \d+ streak bonus coins? = \d+ coins/
    assert_select ".ship-result .projects-hint", text: /You coded 3 hours; the reviewer approved 2 hours/
  end

  test "an unverified user sees the unlock note beside approved coins, a verified one does not" do
    three_hours
    ship = submit_ship(@project)
    travel_to(HOURS_NOW) { Ships::Approve.call(ship: ship, reviewer: @other_user, approved_seconds: 3 * HOUR, now: Time.current) }
    assert_operator Coins::Balance.total(@user), :>, 0, "the coins are credited even though the user is not verified"
    sign_in_as @user

    [ ship_path(ship), ships_path ].each do |path|
      get path
      assert_select ".ship-note", text: /Your coins unlock when you verify your identity with Hack Club/
      assert_select ".ship-note a[href='https://auth.hackclub.com']"
    end

    @user.update_columns(verification_status: "pending")
    get ship_path(ship)
    assert_select ".ship-note", text: /being checked/
    @user.update_columns(verification_status: "verified")
    get ship_path(ship)
    assert_select ".ship-note", 0
  end

  test "a project with a waiting ship cannot be deleted from the projects page" do
    three_hours
    submit_ship(@project)
    sign_in_as @user
    delete project_path(@project)
    assert_redirected_to projects_path
    assert Project.exists?(@project.id)
    follow_redirect!
    assert_select ".flash--alert", text: /Archive it instead/
  end

  test "pages carry no inline styles or scripts" do
    three_hours
    ship = submit_ship(@project)
    sign_in_as @user
    [ ships_path, ship_path(ship) ].each do |path|
      get path
      assert_no_match(/\sstyle="/, response.body)
      assert_select "script:not([src]):not([nonce])", 0
    end
  end

  test "the submitted date is the teen's local date, not the UTC date" do
    three_hours
    @user.update_columns(time_zone: "Pacific Time (US & Canada)")
    ship = submit_ship(@project)
    # 04:40 UTC on Nov 10 is still the evening of Nov 9 in Pacific time.
    ship.update_columns(submitted_at: Time.utc(2026, 11, 10, 4, 40))
    sign_in_as @user

    get ship_path(ship)
    assert_select "dt", "Submitted"
    assert_select "dd", "Nov 9, 2026"
    get ships_path
    assert_select ".ship__meta", /submitted Nov 9\b/
  end

  test "ship text is not written to the request log" do
    three_hours
    sign_in_as @user
    io = StringIO.new
    old = ActionController::Base.logger
    ActionController::Base.logger = ActiveSupport::Logger.new(io)
    begin
      post project_ships_path(@project), params: ship_params(description: "UNIQUE-SHIP-TEXT-456")
    ensure
      ActionController::Base.logger = old
    end
    assert_includes io.string, "Parameters:"
    assert_not_includes io.string, "UNIQUE-SHIP-TEXT-456"
    assert_not_includes io.string, REPO
  end
end
