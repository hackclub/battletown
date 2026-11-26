require "test_helper"
require_relative "../support/shop_helper"
require_relative "../support/bosses_helper"
require_relative "../support/ship_images_helper"
require_relative "../support/ships_test_support"
require_relative "../support/hackatime_helper"

class DashboardTest < ActionDispatch::IntegrationTest
  include ShopTestHelper
  include BossesHelper
  include ShipImagesHelper
  include ShipsTestSupport
  include HackatimeHelper

  # The most SQL statements one dashboard render may run for a typical user (everything on the page at once). The page
  # runs about eighteen; the headroom is for small additions, not for an N+1.
  QUERY_BOUND = 30

  setup do
    OmniAuth.config.test_mode = true
    @user = users(:onboarded)
    @today = Hours::Days.today(@user)
    @user.update_columns(created_at: (@today - 30).in_time_zone("UTC"), signed_up_on: @today - 30) # days before the account existed do not count
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

  def dashboard
    sign_in_as @user
    get dashboard_path
    assert_response :success
  end

  def count_queries
    count = 0
    counter = ->(*, payload) { count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) || payload[:sql].match?(/\A\s*(BEGIN|COMMIT|SAVEPOINT|RELEASE)/i) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end

  # Gives the user everything the page can show: a streak, a boss, coins, a project with a ship, Hackatime, a prize.
  def fill_in_everything(user)
    (1..3).each { |back| add_hours(user, @today - back, 1500) }
    add_hours(user, @today, 1000)
    make_boss(starts_on: @today.beginning_of_week(:friday), hp_seconds: 100 * HOUR)
    give_coins(user, 30)
    project = make_project(user)
    code(user, @today - 1, 3600)
    submit_ship(project)
    connect_hackatime(user)
    user.update_columns(prize_key: "tshirt")
  end

  # --- access ---

  test "signed-out visitors are sent home and the not-onboarded to onboarding" do
    get dashboard_path
    assert_redirected_to root_path
    sign_in_as users(:new_user)
    get dashboard_path
    assert_redirected_to onboarding_path
  end

  # --- what the page is: the whiteboard sketch and nothing else ---

  test "the page is the stage and nothing else: one hidden h1, the stage, no footer, none of the old cards" do
    fill_in_everything(@user)
    dashboard
    assert_select "h1.visually-hidden", count: 1, text: "Dashboard"
    assert_equal [ "stage" ], css_select("main .dashboard > section").map { |node| node["class"].to_s.split.first }
    assert_equal [ "h1", "section" ], css_select("main .dashboard > *").map(&:name)
    assert_select "footer", 0
    %w[dash-today dash-project dash-coins dash-hackatime dash-prize dash-team dash-streak dash-returning dash-firstrun boss-card].each do |old|
      assert_select ".#{old}", 0, "the old #{old} section is gone"
    end
    assert_no_match(/Welcome, /, response.body)
    assert_no_match(/coming soon/i, response.body)
  end

  test "the stage's parts are in reading order: prize, boss health, the boss, the goal, the plan, then the headline, bar and button" do
    fill_in_everything(@user)
    dashboard
    parts = css_select(".stage > *").map { |node| node["class"].to_s.split.first }
    assert_equal %w[stage__top stage__prize-area stage__arena stage__goal stage__plan stage__next], parts
    assert_select "section.stage.on-map[aria-labelledby='stage-title'] h2#stage-title", 1
    assert_select ".stage > .stage__prize-area a.stage__prize[href='#{shop_path}']", /Prize/
    assert_select ".progress.progress--boss progress#stage-boss-health", 1
  end

  test "every native progress element has a label and a text value" do
    fill_in_everything(@user)
    dashboard
    css_select("progress").each do |bar|
      assert css_select("label[for='#{bar["id"]}']").any?, "progress ##{bar["id"]} has no label"
      assert_not bar.text.strip.empty?, "progress ##{bar["id"]} has no fallback text"
      assert bar["aria-describedby"].present?, "progress ##{bar["id"]} has nothing describing it"
    end
  end

  test "no inline styles, no inline scripts and every id is unique" do
    fill_in_everything(@user)
    dashboard
    assert_select "[style]", 0
    assert_select "main script", 0
    ids = css_select("main [id]").map { |node| node["id"] }
    assert_equal ids.uniq.size, ids.size
  end

  test "the Hack Club name is written correctly everywhere" do
    fill_in_everything(@user)
    dashboard
    assert_no_match(/Hackclub|HackClub|\bhack club\b/, response.body)
  end

  # --- the goal card ---

  test "the goal bar never reads more than the goal, cheers a day past it, and carries its three ticks" do
    add_hours(@user, @today, 420 * 60)
    dashboard
    assert_select "progress#dash-today-progress[max='3600'][value='3600']"
    assert_select "#dash-today-text", /Goal smashed! 420 minutes today\./
    assert_select ".goal-card__meter--done"
    ticks = css_select(".goal-tick[data-controller='goal-mark'][aria-hidden='true']")
    assert_equal %w[25.0 50.0 100.0], ticks.map { |t| t["data-goal-mark-percent-value"] }, "the quick mark, the commit mark and the goal"
    assert_equal [ "15 min", "30 min, commit", "60 min, ship" ], ticks.map { |t| t.text.strip }
  end

  test "the daily goal and the plan are always on the page: no button hides them" do
    dashboard
    assert_select "#dash-goal:not([hidden])", 1
    assert_select "#dash-plan:not([hidden])", 1
    assert_select "button.stage__toggle, [data-controller='dash-view'], [data-dash-view-target]", 0
    assert_select ".stage__goal #dash-today-progress", 1
  end

  test "the health bar is a health bar: the bar, the boss's name and what is left on two plates under it" do
    make_boss(starts_on: @today.beginning_of_week(:friday), name: "Grimlord")
    dashboard
    assert_select ".stage__health progress#stage-boss-health", 1
    assert_select ".stage__plates[aria-hidden='true'] .stage__plate--name", "Grimlord"
    assert_select ".stage__plates .stage__plate", 2
    assert_equal 1, css_select("label[for='stage-boss-health']").size, "the bar is named once for assistive tech"
  end

  # --- the stage's next step ---

  test "before the commit mark the stage says the time until the next commit (for assistive tech) and has a Ship button that says why it is waiting" do
    make_project(@user)
    make_boss(starts_on: @today.beginning_of_week(:friday))
    add_hours(@user, @today, 600)
    dashboard
    assert_select "h2#stage-title", "You have about 20 minutes until your next commit. What are you going to do?"
    assert_select "h2#stage-title.visually-hidden", 1, "the sentence is for screen readers: nobody else sees it"
    assert_select ".stage__next progress, .stage__progress, .stage__headline, .stage__hint", 0, "no headline and no progress bar under the boss"
    assert_select "button.stage__cta[disabled][aria-describedby='stage-reason']", "Ship"
    assert_select "#stage-reason", "No coding on this project yet."
  end

  test "a project with some time but not enough says how much is left, in a few words" do
    make_project(@user)
    code(@user, @today - 1, 1800)
    dashboard
    assert_select "#stage-reason", "30 minutes of coding to go."
    assert_select "button.stage__cta[disabled]", 1
  end

  test "the dev add-time buttons are not on the page outside development" do
    make_project(@user)
    dashboard
    assert_select ".stage__dev", 0
  end

  test "past the commit mark the sentence is about shipping, and the button is a link once it can ship" do
    project = make_project(@user)
    code(@user, @today - 1, 1800)
    add_hours(@user, @today, 2000)
    dashboard
    assert_select "h2#stage-title", /until you can ship/
    assert_select ".stage a.stage__cta", 0

    code(@user, @today - 2, 1800)
    get dashboard_path
    assert_select "h2#stage-title", "You have enough coding time to ship Space Farm."
    assert_select ".stage a.stage__cta[href='#{new_project_ship_path(project)}']", "Ship Space Farm"
    assert_select "#stage-reason", 0
  end

  test "the stage's button follows the project: add one, link Hackatime, view a ship" do
    dashboard
    assert_select ".stage a.stage__cta[href='#{new_project_path}']", "Add a project"

    project = make_project(@user, hackatime: nil)
    get dashboard_path
    assert_select ".stage a.stage__cta[href='#{link_project_path(project)}']", "Link a Hackatime project"

    project.hackatime_links.create!(user_id: @user.id, hackatime_project: "space-farm", link_method: "manual")
    code(@user, @today - 3, 3600)
    ship = submit_ship(project)
    get dashboard_path
    assert_select ".stage a.stage__cta[href='#{ship_path(ship)}']", "View your ship"
  end

  test "a project name that was cut short with an ellipsis gets no full stop after it" do
    project = make_project(@user, name: "A tool that automates something…")
    add_hours(@user, @today, 2000) # past the commit mark, with nothing coded on the linked Hackatime project yet
    dashboard
    assert_select "h2#stage-title", "Code on A tool that automates something… to start toward your next ship."

    code(@user, @today - 1, 1800)
    code(@user, @today - 2, 1800)
    get dashboard_path
    assert_select "h2#stage-title", "You have enough coding time to ship A tool that automates something…"
    assert_select "a.stage__cta[href='#{new_project_ship_path(project)}']"
  end

  # --- the boss and the fighters ---

  test "the boss's health, the fighters (decoration only) and the headcount in words" do
    fill_in_everything(@user)
    3.times { |i| add_hours(build_user(created_on: @today - 30), @today, 1200 + i) }
    dashboard
    assert_select ".stage__crowd[aria-hidden='true'] .stage__fan", 4, "one circle per person who coded today, you included"
    assert_select ".stage__fan", text: /./, count: 0, message: "the circles carry no names, avatars or text"
    assert_equal 1, response.body.scan(/4 people coded today/).size, "the headcount is said once, in words"
    assert_select ".stage__art[alt]", 1
  end

  test "a boss with its own picture shows it on the stage with its own alt text" do
    boss = make_boss(starts_on: @today.beginning_of_week(:friday))
    boss.attach_art(ShipImages::Processor.call(upload_file(png_bytes(64, 32)), config: Bosses::ArtConfig.current))
    boss.art_alt = "A boss in a very big hat"
    boss.save!
    dashboard
    assert_select "img.stage__art[src=?][alt=?]", boss.art_path, "A boss in a very big hat", 1
  end

  test "at most twelve fighters are drawn however many people coded" do
    make_boss(starts_on: @today.beginning_of_week(:friday))
    15.times { add_hours(build_user(created_on: @today - 30), @today, 1200) }
    dashboard
    assert_select ".stage__fan", 12
    assert_includes response.body, "15 people coded today"
  end

  test "no boss: the stage says so and still shows the prize and the next step" do
    dashboard
    assert_select ".stage--none .stage__none"
    assert_select ".stage__arena", 0
    assert_select ".stage__prize", 1
    assert_select "h2#stage-title", 1
  end

  test "a defeated boss still renders the whole stage, greyed, and says so in words" do
    boss = make_boss(starts_on: @today.beginning_of_week(:friday), hp_seconds: 3600)
    Bosses::CheckDefeat.for_ship(ship_damage(@user, 4000, on: @today)) # a ship, not coding, is what hurts the boss
    assert boss.reload.defeated?
    dashboard
    assert_select ".stage--defeated .stage__art"
    assert_includes response.body, "Boss defeated."
    assert_select "a.stage__cta, button.stage__cta"
  end

  # --- the prize check ---

  test "beside the prize: whether it is on pace, the time to go with the bonus, the plan and a way to change the pace" do
    fill_in_everything(@user)
    dashboard
    assert_select ".stage__prize-area .stage__pace .stage__pace-badge", /On track|Behind|Just starting|Enough for it/
    assert_select ".stage__pace-line", /of coding to go|You have the coins|Ship your time/
    assert_select ".stage__pace-plan a[href='#{onboarding_step_path("schedule")}']", "Change pace"
  end

  test "an active streak bonus is named next to the time to go" do
    (1..3).each { |back| add_hours(@user, @today - back, 1500) }
    dashboard
    assert_select ".stage__pace-line", /with your \d+(\.\d)?% bonus\./
  end

  test "nobody else's pace, coins or prize shows in the corner" do
    other = build_user(created_on: @today - 30)
    other.update_columns(prize_key: "sticker_pack", onboarded_at: Time.current, pace_minutes: 240)
    give_coins(other, 777)
    dashboard
    assert_not_includes response.body, "777"
    assert_not_includes response.body, "240 minutes"
  end

  # --- the to-do boxes ---

  test "a person with a project sees one empty line, with its own label and a save button" do
    make_project(@user)
    dashboard
    assert_select "#dash-plan h2", "What are you working on today?"
    assert_select "form[action='#{dashboard_todos_path}'] input[name='_method'][value='patch']", 1
    assert_select "label.visually-hidden[for='todo-body-1']", "Thing you are working on, number 1"
    assert_select "input#todo-body-1[name='todos[1][body]'][maxlength='120'][value='']", 1
    assert_select "input#todo-done-1[type=checkbox][name='todos[1][done]']", 1
    assert_select ".plan__lines .plan__input", 1, "never more than one empty line"
    assert_select ".plan__lines .plan__check", 1
  end

  test "their items come first, then exactly one empty line; a full list has none" do
    project = make_project(@user)
    project.update!(todos: [ { "body" => "Build the login form", "done" => true }, { "body" => "Fix the header", "done" => false } ])
    dashboard
    assert_select ".plan__lines .plan__input", 3
    assert_select "#todo-body-1[value='Build the login form']"
    assert_select "#todo-done-1[checked]"
    assert_select "#todo-body-2[value='Fix the header']"
    assert_select "#todo-done-2[checked]", 0
    assert_select "#todo-body-3[value='']", 1

    project.update!(todos: Array.new(Project::TODOS_MAX) { |i| { "body" => "Thing #{i + 1}", "done" => false } })
    get dashboard_path
    assert_select ".plan__lines .plan__input", Project::TODOS_MAX
    assert_select ".plan__lines .plan__input[value='']", 0, "no empty line once the list is full"
  end

  test "the page carries a blank line for its script to copy, outside the form's fields, and the limit" do
    make_project(@user)
    dashboard
    assert_select "#dash-plan[data-todo-autosave-limit-value='#{Project::TODOS_MAX}']"
    assert_select "template[data-todo-autosave-target='template'] input[name='todos[__SLOT__][body]']", 1
    assert_select "form > .plan__lines input[name='todos[__SLOT__][body]']", 0
  end

  test "saving keeps their items in order, drops blanks and gaps, cuts each to size and keeps the ticks" do
    project = make_project(@user)
    sign_in_as @user
    patch dashboard_todos_path, params: { todos: { "1" => { body: "  Build the login form ", done: "1" }, "2" => { body: "" },
                                                    "4" => { body: "Fix the header" }, "3" => { body: "x" * 300 } } }
    assert_redirected_to dashboard_path
    assert_equal [ "Build the login form", "x" * 120, "Fix the header" ], project.reload.todos.map { |item| item["body"] }, "in the order of the numbers, the blank gone"
    assert_equal [ true, false, false ], project.todos.map { |item| item["done"] }

    get dashboard_path
    assert_select "#todo-body-1[value='Build the login form']"
    assert_select "#todo-done-1[checked]"
    assert_select "#todo-body-4[value='']", 1, "the empty line comes after the three"
  end

  test "no more than the limit is kept however many lines are sent" do
    project = make_project(@user)
    sign_in_as @user
    lines = (1..60).to_h { |i| [ i.to_s, { body: "Thing #{i}" } ] }
    patch dashboard_todos_path, params: { todos: lines }
    assert_equal Project::TODOS_MAX, project.reload.todos.size
    assert_equal "Thing 1", project.todos.first["body"]
  end

  test "the list saves itself: wired to todo-autosave, the Save button stays for people without JavaScript, and a background save needs nothing back" do
    project = make_project(@user)
    dashboard
    assert_select "#dash-plan[data-controller='todo-autosave']"
    assert_select "form[data-todo-autosave-target='form'] button[data-todo-autosave-target='save']", "Save"
    assert_select ".plan__lines input.plan__input[data-action='input->todo-autosave#typed change->todo-autosave#save']", 1
    assert_select ".plan__lines input.plan__check[data-action='change->todo-autosave#save']", 1
    assert_select "p.plan__status[role='status'][data-todo-autosave-target='status']", 1

    patch dashboard_todos_path, params: { todos: { "1" => { body: "Draw the map" } } }, headers: { "Accept" => "application/json" }
    assert_response :no_content
    assert_equal [ { "body" => "Draw the map", "done" => false } ], project.reload.todos
  end

  test "the database holds at most ten items too" do
    project = make_project(@user)
    eleven = Array.new(11) { |i| { "body" => "t#{i}", "done" => false } }
    assert_not project.update(todos: eleven), "the model refuses an eleventh item"
    assert_raises(ActiveRecord::StatementInvalid) { Project.transaction(requires_new: true) { project.update_columns(todos: eleven) } }
  end

  test "a background save without a project says it could not" do
    sign_in_as @user
    patch dashboard_todos_path, params: { todos: { "1" => { body: "x" } } }, headers: { "Accept" => "application/json" }
    assert_response :unprocessable_content
  end

  test "an item is cut at 120 characters and the list can be cleared" do
    project = make_project(@user)
    sign_in_as @user
    patch dashboard_todos_path, params: { todos: { "1" => { body: "x" * 300 } } }
    assert_equal 120, project.reload.todos.first["body"].length
    patch dashboard_todos_path, params: { todos: { "1" => { body: "" } } }
    assert_equal [], project.reload.todos
    patch dashboard_todos_path
    assert_equal [], project.reload.todos
  end

  test "the boxes belong to the active project of the signed-in person only" do
    mine = make_project(@user)
    other = build_user(created_on: @today - 30)
    other.update_columns(onboarded_at: Time.current)
    theirs = make_project(other, name: "Zed's Secret Plans", hackatime: "zed-hackatime")
    theirs.update!(todos: [ { "body" => "Zed's secret task", "done" => false } ])
    sign_in_as @user
    patch dashboard_todos_path, params: { project_id: theirs.id, todos: { "1" => { body: "Mine" } } }
    assert_equal [ { "body" => "Mine", "done" => false } ], mine.reload.todos
    assert_equal [ { "body" => "Zed's secret task", "done" => false } ], theirs.reload.todos
    get dashboard_path
    assert_not_includes response.body, "Zed's secret task"
  end

  test "without a project there are no boxes to save, and saving says to add a project" do
    dashboard
    assert_select "#dash-plan form", 0
    assert_select ".plan__empty", /Add a project/
    patch dashboard_todos_path, params: { todos: { "1" => { body: "x" } } }
    assert_redirected_to dashboard_path
    follow_redirect!
    assert_select ".flash", /Add a project first/
  end

  test "signed-out and not-onboarded people cannot save the boxes" do
    patch dashboard_todos_path, params: { todos: { "1" => { body: "x" } } }
    assert_redirected_to root_path
    sign_in_as users(:new_user)
    patch dashboard_todos_path, params: { todos: { "1" => { body: "x" } } }
    assert_redirected_to onboarding_path
  end

  test "after a ship is sent back the reviewer's note shows above the box, and goes once the player ships again" do
    project = make_project(@user)
    code(@user, @today - 3, 3600)
    ship = submit_ship(project)
    Ships::Reject.call(ship: ship, reviewer: users(:new_user), reason: "The demo link does not open")
    dashboard
    assert_select ".plan__review", /Your last ship needs changes: The demo link does not open/
    assert_select "#todo-body-1[value='']", 1, "the line is theirs to fill in"

    patch dashboard_todos_path, params: { todos: { "1" => { body: "Fix the demo link" } } }
    get dashboard_path
    assert_select "#todo-body-1[value='Fix the demo link']"
    assert_select ".plan__review", 1, "the reviewer's note stays beside it"
  end

  test "the to-do text is never logged" do
    make_project(@user)
    sign_in_as @user
    logged = capture_logs { patch dashboard_todos_path, params: { todos: { "1" => { body: "PROBE-TODO-TEXT" } } } }
    assert_not_includes logged, "PROBE-TODO-TEXT"
  end

  # --- resilience and privacy ---

  test "a failing settle does not break the page and only its class is logged" do
    add_hours(@user, @today - 1, 900)
    original = Game::Settle.method(:call)
    Game::Settle.define_singleton_method(:call) { |*, **| raise ArgumentError, "secret detail Somebody <somebody@example.com>" }
    logged = capture_logs do
      dashboard
    end
    assert_select "section.stage"
    assert_includes logged, "dashboard settle failed error=ArgumentError"
    assert_not_includes logged, "somebody@example.com"
  ensure
    Game::Settle.define_singleton_method(:call, original)
  end

  test "no other user's name, email, Slack id, project or ship ever appears" do
    other = build_user(created_on: @today - 30)
    other.update_columns(display_name: "Zed Zebra-Person", email: "zed.person@example.com", slack_id: "U0ZEDSLACK",
                         prize_key: "tshirt", onboarded_at: Time.current, verification_status: "verified")
    other_project = make_project(other, name: "Zed's Secret Plans", hackatime: "zed-hackatime")
    code(other, @today - 1, 3600, hackatime: "zed-hackatime")
    submit_ship(other_project, description: "Zed secret description")
    give_coins(other, 777)
    add_hours(other, @today, 1500)
    fill_in_everything(@user)
    dashboard

    body = response.body
    [ "Zed", "zed.person", "U0ZEDSLACK", "Secret Plans", "zed-hackatime", "777" ].each { |secret| assert_not body.include?(secret), "the page leaked #{secret.inspect}" }
    assert_includes body, "2 people coded today" # only a headcount: this user and the other one
  end

  test "a typical user's dashboard runs a bounded number of queries" do
    fill_in_everything(@user)
    sign_in_as @user
    get dashboard_path # warm anything lazy (config, route caches)
    queries = count_queries { get dashboard_path }
    assert_response :success
    assert_operator queries, :<=, QUERY_BOUND, "dashboard ran #{queries} queries"
  end

  test "the number of queries does not grow with the number of days, ships or other users" do
    fill_in_everything(@user)
    sign_in_as @user
    get dashboard_path
    baseline = count_queries { get dashboard_path }

    (4..40).each { |back| add_hours(@user, @today - back, 900) }
    5.times { build_user(created_on: @today - 30).tap { |other| add_hours(other, @today, 900) } }
    more = count_queries { get dashboard_path }
    assert_operator more, :<=, baseline + 3, "baseline #{baseline}, with more data #{more}"
  end
end
