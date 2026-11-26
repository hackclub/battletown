require "test_helper"
require_relative "../support/bosses_helper"
require_relative "../support/dev_simulator_test_support"
require_relative "../support/fighters_helper"

# The dashboard's event simulator: the panel is in the page only in development (with a local database), and its JSON endpoints
# are development-only, login-only, CSRF-protected and aggregate-only. Development is faked the way dev_boss_test.rb does.
class DevSimulatorPanelTest < ActionDispatch::IntegrationTest
  include DevSimulatorTestSupport
  include FightersHelper

  # Every memoized config read from config/game.yml, whose `development:` section differs from `test:` (ships.project_time_from,
  # for one). Whatever a request loads under the faked environment is put back as it was, so nothing leaks into later tests.
  CONFIGS = %w[Ships Hours Bosses Game Teams Quests Eligibility Orders Notifications MerchTrack Nps ShipImages ShopItems AdminUsers Plinko].freeze

  def in_env(name)
    original = Rails.env
    memos = CONFIGS.to_h { |prefix| [ "#{prefix}::Config".constantize, "#{prefix}::Config".constantize.instance_variable_get(:@current) ] }
    Rails.env = name
    yield
  ensure
    Rails.env = original
    memos&.each { |config, memo| config.instance_variable_set(:@current, memo) }
  end

  setup do
    local_database!
    OmniAuth.config.test_mode = true
    @detailed = Rails.application.env_config["action_dispatch.show_detailed_exceptions"]
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = false
    @user = users(:onboarded)
    @user.update_columns(created_at: (utc_today - 30).in_time_zone("UTC"), signed_up_on: utc_today - 30)
    @boss = make_current_boss(hp_seconds: 100 * HOUR)
  end

  teardown do
    restore_database_host!
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = @detailed
  end

  def sign_in_as(user)
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
  end

  def json = JSON.parse(response.body)

  def dev_post(path, params = {}, env: "development")
    in_env(env) { post path, params: params.to_json, headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json" } }
  end

  # --- the panel ---

  test "the panel is in the dashboard in development, closed, with its labels and no inline script" do
    sign_in_as @user
    in_env("development") { get dashboard_path }

    assert_response :success
    assert_select "details.event-simulator[data-controller='event-simulator']", 1
    assert_select "details.event-simulator[open]", 0
    assert_select "details.event-simulator summary", text: /event simulator/
    assert_select "details.event-simulator summary [data-event-simulator-target=readout]", 1
    assert_select "details.event-simulator", text: /Browser only/
    assert_select "details.event-simulator", text: /Writes to your dev database/
    [ "apply preview", "restore live values", "create players", "everyone ships", "random 30% ship", "remove simulated players" ].each do |label|
      assert_select "details.event-simulator button", text: label
    end
    assert_select "details.event-simulator input[type=range][name=damage][min='0'][max='100']", 1
    assert_select "details.event-simulator input[name=count][min='1'][max='200']", 1
    assert_select "details.event-simulator input[name=hours_min][value='1'][max='100']", 1
    assert_select "details.event-simulator input[name=hours_max][value='8'][max='100']", 1
    assert_select "details.event-simulator input[name=seconds][value='4'][min='2'][max='120']", 1
    assert_select "details.event-simulator input[type=radio][name=hit_size]", 3
    assert_select "details.event-simulator input[type=radio][name=hit_size][value='1'][checked]", 1
    %w[1 5 20].each { |factor| assert_select "details.event-simulator input[type=radio][name=hit_size][value='#{factor}']", 1 }
    assert_select "details.event-simulator [data-event-simulator-target=countdown][aria-hidden=true]", 1
    assert_select "details.event-simulator script", 0
    assert_select "details.event-simulator [style]", 0
    assert_select "details.event-simulator[data-event-simulator-ship-url-value='/dev/simulator/ship']", 1
    # The ids the panel rewrites are on the page.
    assert_select "progress#stage-boss-health", 1
    assert_select ".stage__plate", 2
    assert_select "#stage-boss-summary", 1
  end

  test "the live header (message and numbers) comes first in the open panel, the preview last" do
    sign_in_as @user
    in_env("development") { get dashboard_path }

    assert_select ".event-simulator__body > :first-child.event-simulator__live" do
      assert_select "[role=status][aria-live=polite][data-event-simulator-target=message]", 1
      assert_select "dl.event-simulator__numbers dd[data-event-simulator-target=stat]", 7
      %w[boss damage health togo players coded shipped].each { |key| assert_select "dd[data-stat='#{key}']", 1 }
    end
    assert_select ".event-simulator__body > form:last-child[aria-labelledby=simulator-preview-title]", 1
  end

  test "the panel is not in the page in test or production, or against a database that is not local" do
    sign_in_as @user

    get dashboard_path
    assert_response :success
    assert_select "details.event-simulator", 0
    assert_no_match(/event simulator/, response.body)

    in_env("production") { get dashboard_path }
    assert_select "details.event-simulator", 0

    DevSimulator.define_singleton_method(:effective_host) { "db.example.com" }
    in_env("development") { get dashboard_path }
    assert_response :success
    assert_select "details.event-simulator", 0
  end

  # --- the endpoints ---

  test "every endpoint is a 404 outside development, signed in or not" do
    sign_in_as @user
    %w[test production].each do |env|
      in_env(env) { get "/dev/simulator/status" }
      assert_response :not_found, env
      %w[create_players ship reset].each do |action|
        dev_post("/dev/simulator/#{action}", { count: 3, mode: "all" }, env: env)
        assert_response :not_found, "#{env} #{action}"
      end
    end
    assert_equal 0, DevSimulator.players.count
  end

  test "signed-out visitors are sent to sign in" do
    in_env("development") { get "/dev/simulator/status" }
    assert_redirected_to root_path
    dev_post("/dev/simulator/create_players", { count: 3 })
    assert_redirected_to root_path
    assert_equal 0, DevSimulator.players.count
  end

  test "status is aggregates only" do
    sign_in_as @user
    in_env("development") { get "/dev/simulator/status" }

    assert_response :success
    status = json["status"]
    assert_equal @boss.name, status.dig("boss", "name")
    assert_equal 0, status["players"]
    assert_equal 0, status.dig("boss", "damage_seconds")
    assert_equal "Full health", status.dig("boss", "health_text")
  end

  test "create players, ship, and the boss takes damage; each answer carries the numbers to redraw the page" do
    sign_in_as @user

    dev_post("/dev/simulator/create_players", { count: 6 })
    assert_response :success
    assert_match(/6 created/, json["message"])
    assert_equal 6, json.dig("status", "players")
    assert_equal 6, json.dig("status", "people_coded")
    assert_equal 0, json.dig("status", "people_shipped")
    assert_equal 6, json.dig("status", "last", "created")

    dev_post("/dev/simulator/ship", { mode: "all", hours_min: 2, hours_max: 2 })
    assert_response :success
    assert_equal 6, json.dig("status", "last", "shipped")
    assert_equal 12 * HOUR, json.dig("status", "boss", "damage_seconds")
    assert_equal 12 * HOUR, Bosses::Damage.for(@boss)
    assert_equal "88% left", json.dig("status", "boss", "health_text")
    assert_equal 88, json.dig("status", "boss", "health_percent")
    assert_equal 6, json.dig("status", "simulated_ships_this_week")
    assert_equal [ 6, 6 ], json["status"].values_at("people_coded", "people_shipped"), "everybody who shipped coded in the last day"
    assert_not_includes response.body, "sim!"

    dev_post("/dev/simulator/ship", { mode: "percent", percent: 50, hours_min: 1, hours_max: 1 })
    assert_equal 3, json.dig("status", "last", "shipped")
  end

  test "the dashboard shows the damage the simulator dealt (the same numbers the panel redraws)" do
    sign_in_as @user
    dev_post("/dev/simulator/create_players", { count: 4 })
    dev_post("/dev/simulator/ship", { mode: "all", hours_min: 5, hours_max: 5 })

    in_env("development") { get dashboard_path }

    assert_select "progress#stage-boss-health[value='80']", 1
    assert_select ".stage__fan", 4
    assert_select ".stage__fan a.stage__fighter[href^='/players/']", 4, "simulated players have public profiles: links"
    assert_select ".stage__fan--hit-ship", 4, "they all shipped"
    assert_match(/Boss at 80% health/, css_select("#stage-boss-summary").text)
  end

  test "the stage sees what an action did at once, not after the 20 second cache" do
    sign_in_as @user
    swap_cache do
      in_env("development") { get dashboard_path }
      assert_select ".stage__fan", 0

      dev_post("/dev/simulator/create_players", { count: 3 })
      in_env("development") { get dashboard_path }
      assert_select ".stage__fan", 3
      get boss_fighters_path
      assert_equal 3, json["total"]
    end
  end

  test "the panel hands the circles to the stage: it sends boss:refresh after each action and draws none itself" do
    js = Rails.root.join("app/javascript/controllers/event_simulator_controller.js").read
    assert_match(/new CustomEvent\("boss:refresh"\)/, js)
    assert_no_match(/stage__crowd|stage__fan|createElement\("li"\)/, js)
    assert_no_match(/people_coded_today|MAX_FANS/, js)
  end

  test "a hit of up to 100 hours per ship is allowed, and the answer says how many hours hit the boss" do
    sign_in_as @user
    @boss.update_columns(hp_seconds: 500 * HOUR)
    dev_post("/dev/simulator/create_players", { count: 2 })

    dev_post("/dev/simulator/ship", { mode: "all", hours_min: 100, hours_max: 100 })

    assert_response :success
    assert_equal 200 * HOUR, json.dig("status", "boss", "damage_seconds")
    assert_equal 200 * HOUR, json.dig("status", "last", "hit_seconds")
    assert_match(/2 of 2 shipped\. 200\.0 hours hit the boss\./, json["message"])
  end

  test "defaults to hours 1 to 8 when the panel sends none" do
    sign_in_as @user
    dev_post("/dev/simulator/create_players", { count: 3 })

    dev_post("/dev/simulator/ship", { mode: "all" })

    assert_response :success
    assert_includes (3 * HOUR)..(24 * HOUR), json.dig("status", "last", "seconds")
  end

  test "actions that change nothing say so plainly" do
    sign_in_as @user

    dev_post("/dev/simulator/ship", { mode: "all" })
    assert_response :unprocessable_content
    assert_equal "No players yet: create some first.", json["error"]

    dev_post("/dev/simulator/reset", {})
    assert_response :success
    assert_match(/Nothing to remove/, json["message"])

    dev_post("/dev/simulator/create_players", { count: 2 })
    dev_post("/dev/simulator/create_players", { count: 2 })
    assert_match(/Nothing changed/, json["message"])
    assert_equal 0, json.dig("status", "last", "created")
  end

  test "a ship that cannot hurt the boss says why, and floats no damage" do
    sign_in_as @user
    @boss.update_columns(hp_seconds: 4 * HOUR)
    dev_post("/dev/simulator/create_players", { count: 3 })
    dev_post("/dev/simulator/ship", { mode: "all", hours_min: 2, hours_max: 2 })
    assert_equal "defeated", json.dig("status", "boss", "state")
    assert_match(/The boss is defeated!/, json["message"])
    assert_equal 6 * HOUR, json.dig("status", "last", "hit_seconds")

    dev_post("/dev/simulator/ship", { mode: "all", hours_min: 2, hours_max: 2 })

    assert_response :success
    assert_match(/already defeated, so the bar cannot move/, json["message"])
    assert_equal 0, json.dig("status", "last", "hit_seconds")
    assert_equal 3, json.dig("status", "last", "shipped")

    Boss.delete_all
    dev_post("/dev/simulator/ship", { mode: "all", hours_min: 1, hours_max: 1 })
    assert_match(/no boss this week to hit/, json["message"])
    assert_equal 0, json.dig("status", "last", "hit_seconds")
  end

  test "a ship nobody can make says the boss took no damage" do
    sign_in_as @user
    dev_post("/dev/simulator/create_players", { count: 1 })
    Project::MAX_PER_USER.times { dev_post("/dev/simulator/ship", { mode: "all", hours_min: 1, hours_max: 1 }) }

    dev_post("/dev/simulator/ship", { mode: "all", hours_min: 1, hours_max: 1 })

    assert_response :success
    assert_match(/Nobody shipped \(skipped 1 no project\)\. The boss took no damage\./, json["message"])
    assert_equal 0, json.dig("status", "last", "shipped")
  end

  test "a boss that falls from simulated ships stays down, and remove takes the players away" do
    sign_in_as @user
    @boss.update_columns(hp_seconds: 10 * HOUR)
    dev_post("/dev/simulator/create_players", { count: 6 })
    dev_post("/dev/simulator/ship", { mode: "all", hours_min: 2, hours_max: 2 })

    assert_equal "defeated", json.dig("status", "boss", "state")
    assert_not_nil @boss.reload.defeated_at

    dev_post("/dev/simulator/reset", {})
    assert_response :success
    assert_match(/Removed 6/, json["message"])
    assert_equal 0, json.dig("status", "players")
    assert_equal 0, DevSimulator.players.count
    assert_not_nil @boss.reload.defeated_at

    dev_post("/dev/simulator/reset", { clear_defeat: true })
    assert_nil @boss.reload.defeated_at
  end

  test "out-of-range numbers are refused with a clear message and write nothing" do
    sign_in_as @user

    dev_post("/dev/simulator/create_players", { count: 5000 })
    assert_response :unprocessable_content
    assert_match(/players must be a whole number from 1 to 200/, json["error"])

    dev_post("/dev/simulator/create_players", { count: 2 })
    dev_post("/dev/simulator/ship", { mode: "all", hours_min: 1, hours_max: 101 })
    assert_response :unprocessable_content
    assert_match(/hours per ship \(max\) must be a number from 1 to 100/, json["error"])
    dev_post("/dev/simulator/ship", { mode: "all", hours_min: 0.5, hours_max: 2 })
    assert_response :unprocessable_content
    assert_match(/hours per ship/, json["error"])
    dev_post("/dev/simulator/ship", { mode: "nonsense" })
    assert_response :unprocessable_content
    assert_equal 0, Ship.count
  end

  test "a database that is not local is refused with a clear message" do
    sign_in_as @user
    DevSimulator.define_singleton_method(:effective_host) { "db.example.com" }

    dev_post("/dev/simulator/create_players", { count: 2 })

    assert_response :unprocessable_content
    assert_match(/only writes to a database on this machine/, json["error"])
    assert_equal 0, User.where("hca_uid LIKE 'sim!%'").count
  end

  test "the writes are CSRF-protected" do
    sign_in_as @user
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    begin
      dev_post("/dev/simulator/create_players", { count: 2 })
      assert_response :unprocessable_content
      assert_equal 0, DevSimulator.players.count
    ensure
      ActionController::Base.allow_forgery_protection = original
    end
  end

  test "real users are never touched" do
    sign_in_as @user
    before = @user.reload.attributes

    dev_post("/dev/simulator/create_players", { count: 3 })
    dev_post("/dev/simulator/ship", { mode: "all" })
    dev_post("/dev/simulator/reset", {})

    assert_equal before, @user.reload.attributes
    assert_equal 0, Ship.where(user: @user).count
  end
end
