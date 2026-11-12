require "test_helper"
require_relative "../support/shop_helper"
require_relative "../support/bosses_helper"
require_relative "../support/ships_test_support"
require_relative "../support/hackatime_helper"

class DashboardTest < ActionDispatch::IntegrationTest
  include ShopTestHelper
  include BossesHelper
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

  # --- structure and accessibility ---

  test "renders for a typical user with one h1, an h2 per section and the old placeholder gone" do
    fill_in_everything(@user)
    dashboard
    assert_select "h1", count: 1
    assert_select "h1", /Welcome, Veteran/
    sections = css_select("main h2").map { |h2| h2.text.strip }
    assert_equal [ "Weekly boss", "Today", "Streaks", "Coins", "Active project", "Hackatime", "Your prize" ].size, sections.size
    assert_includes sections, "Today"
    assert_includes sections, "Streaks"
    assert_includes sections, "Coins"
    assert_includes sections, "Active project"
    assert_includes sections, "Hackatime"
    assert_includes sections, "Your prize"
    assert_no_match(/coming soon/i, response.body)
    assert_select "strong", /T-shirt/
  end

  test "every native progress element has a label and a text value" do
    fill_in_everything(@user)
    dashboard
    bars = css_select("progress")
    assert_operator bars.size, :>=, 3 # boss health, today, prize
    bars.each do |bar|
      assert bar["id"].present?, "progress without an id"
      assert_select "label[for='#{bar['id']}']", 1
      assert bar.text.strip.present?, "progress without fallback text"
      assert bar["max"].present? && bar["value"].present?
    end
    assert_select "progress#dash-today-progress[max='3600']"
  end

  test "the today panel never reads more than the goal and cheers a day past it" do
    add_hours(@user, @today, 420 * 60)
    dashboard

    assert_select ".dash-meter.dash-meter--done.dash-meter--smashed", 1
    assert_select "progress#dash-today-progress[max='3600'][value='3600']", "60 of 60 minutes"
    assert_select "#dash-today-text", "Goal smashed! 420 minutes today."
    assert_select ".dash-check--done", 2
    assert_no_match(/420 of 60/, response.body)
  end

  test "no inline styles, no inline scripts and every heading id is unique" do
    fill_in_everything(@user)
    dashboard
    assert_select "[style]", 0
    assert_select "main script", 0
    ids = css_select("main [id]").map { |node| node["id"] }
    assert_equal ids.uniq.size, ids.size
  end

  test "icons are decoration only and the streak says its state in words" do
    fill_in_everything(@user)
    dashboard
    assert_select ".dash-streak__icon[aria-hidden='true']", 2
    assert_select "article.dash-streak--active .dash-streak__count strong", "4 days"
    assert_select "[role='status']", 0 # nothing on a calm page is a live message
  end

  test "the Hack Club name is written correctly everywhere" do
    fill_in_everything(@user)
    dashboard
    assert_no_match(/Hackclub|HackClub|\bhack club\b/, response.body)
  end

  # --- states ---

  test "a brand-new user sees the first-run prompt and the Hackatime connect link" do
    @user.update_columns(prize_key: nil)
    dashboard
    assert_select ".dash-callout", /Code for 15 minutes to start your streak\./
    assert_select ".dash-callout a[href='#{hackatime_path}']", "Connect Hackatime"
    assert_select "article.dash-streak--empty", 2
    assert_select ".dash-bonus", /Hit 15 minutes to start a streak: today's bonus is 5% once the day closes\./
    assert_select "section.dash-prize", 0
    assert_select ".dash-project", /Add a project/
    assert_select "a[href='#{new_project_path}']", text: "Add a project"
  end

  test "the first-run prompt does not push Hackatime on someone already connected" do
    connect_hackatime(@user)
    dashboard
    assert_select ".dash-callout a[href='#{hackatime_path}']", 0
    assert_select ".dash-callout", /Hackatime is connected\./
    assert_select ".dash-hackatime", /Connected/
  end

  test "an active streak shows the projected bonus honestly" do
    (1..2).each { |back| add_hours(@user, @today - back, 900) }
    dashboard
    assert_select ".dash-bonus", /Hit 15 minutes to keep your streak: today's bonus is 8\.1% once the day closes\./
    assert_select ".dash-facts li", text: /Freeze ready/
  end

  test "a broken streak is encouraging" do
        (9..11).each { |back| add_hours(@user, @today - back, 900) }
    dashboard
    assert_select "article.dash-streak--broken .dash-streak__message", /A fresh start\. Your best was 3 days\./
  end

  test "an unverified user with coins sees the lock note and the verify link, a verified one does not" do
    give_coins(@user, 40)
    dashboard
    assert_select ".dash-coins strong", "40 coins"
    assert_select ".dash-coins", /Spendable now:\s*0 coins/
    assert_select ".dash-coins .ship-note a[href='https://auth.hackclub.com']", "Verify with Hack Club"
    assert_select ".dash-coins a[href='#{shop_path}']"

    @user.update_columns(verification_status: "verified")
    get dashboard_path
    assert_select ".dash-coins .ship-note", 0
    assert_select ".dash-coins", { text: /Spendable now/, count: 0 }
  end

  test "orders are linked once there are some" do
    verified!(@user)
    give_coins(@user, 100)
    buy(@user)
    dashboard
    assert_select ".dash-coins a[href='#{orders_path}']"
  end

  test "an eligible project has a primary Ship button, a short one says why not" do
    project = make_project(@user)
    code(@user, @today - 1, 1800)
    dashboard
    assert_select ".dash-project a.btn--primary", 0
    assert_select ".dash-reason", "You need at least 1 hour on this project to ship. You have 30 minutes so far, 30 minutes to go."

    code(@user, @today - 2, 1800)
    get dashboard_path
    assert_select ".dash-project a.btn--primary[href='#{new_project_ship_path(project)}']", "Ship"
    assert_select ".dash-reason", 0
  end

  test "a project without a Hackatime link says to link one" do
    project = make_project(@user, hackatime: nil)
    dashboard
    assert_select ".dash-reason", /Link a Hackatime project/
    assert_select ".dash-project a[href='#{edit_project_path(project)}']", text: "Link a Hackatime project"
  end

  test "ship statuses: waiting, approved and rejected with its reason" do
    project = make_project(@user)
    code(@user, @today - 3, 3600)
    ship = submit_ship(project)
    dashboard
    assert_select ".dash-ship .badge", "Waiting for review"
    assert_select ".dash-project a[href='#{ship_path(ship)}']", text: "View your ship"
    assert_select ".dash-project a[href='#{ships_path}']", text: "All your ships"

    Ships::Reject.call(ship: ship, reviewer: users(:new_user), reason: "The demo link does not open")
    get dashboard_path
    assert_select ".dash-ship .badge", "Needs changes"
    assert_select ".dash-ship__reason", "Reviewer note: The demo link does not open"
    assert_select ".dash-ship a[href='#{new_project_ship_path(project, from: ship.id)}']", text: "Fix and ship again"

    second = submit_ship(project)
    Ships::Approve.call(ship: second, reviewer: users(:new_user), approved_seconds: 3600, now: Time.current)
    get dashboard_path
    assert_select ".dash-ship .badge", "Approved"
    assert_select ".dash-ship", /1 hour approved, \d+ coins? earned\./
  end

  test "approving a ship updates the coin and prize panels" do
    @user.update_columns(prize_key: "tshirt")
    project = make_project(@user)
    code(@user, @today - 3, 7200)
    ship = submit_ship(project)
    dashboard
    assert_select ".dash-coins strong", "0 coins"
    assert_select "progress#dash-prize-progress[value='0'][max='50']"
    Ships::Approve.call(ship: ship, reviewer: users(:new_user), approved_seconds: 7200, now: Time.current)
    get dashboard_path
    assert_select ".dash-coins strong", "#{Coins::Balance.total(@user)} coins"
    assert_select "progress#dash-prize-progress[value='#{[ Coins::Balance.total(@user), 50 ].min}']"
  end

  test "Hackatime: needs reconnect shows the reconnect link" do
    connect_hackatime(@user).mark_needs_reconnect!("token_revoked")
    dashboard
    assert_select ".dash-hackatime", /Needs reconnecting/
    assert_select ".dash-hackatime a[href='#{hackatime_path}']", text: "Reconnect Hackatime"
  end

  test "a defeated boss shows its banner and still renders the rest" do
    boss = make_boss(starts_on: @today.beginning_of_week(:friday), hp_seconds: 3600)
    add_hours(@user, @today, 4000)
    assert boss.reload.defeated?
    dashboard
    assert_select ".boss-card--defeated .boss-card__banner[role='status']"
    assert_select "section.dash-today"
  end

  test "the community headcount is shown once, from the boss card" do
    make_boss(starts_on: @today.beginning_of_week(:friday))
    other = build_user(created_on: @today - 30)
    add_hours(other, @today, 1200)
    dashboard
    assert_equal 1, response.body.scan(/1 person coded today/).size
  end

  # --- resilience ---

  test "a failing settle does not break the page and only its class is logged" do
    add_hours(@user, @today - 1, 900)
    original = Game::Settle.method(:call)
    Game::Settle.define_singleton_method(:call) { |*, **| raise ArgumentError, "secret detail Somebody <somebody@example.com>" }
    logged = capture_logs do
      dashboard
    end
    assert_select "h1", /Welcome/
    assert_select "article.dash-streak--active", /1 day/
    assert_includes logged, "dashboard settle failed error=ArgumentError"
    assert_not_includes logged, "somebody@example.com"
  ensure
    Game::Settle.define_singleton_method(:call, original)
  end

  # --- privacy ---

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
    assert_select "h1", /Veteran/
  end

  test "the page shows only the signed-in user's own streak and coins" do
    other = build_user(created_on: @today - 30)
    (1..9).each { |back| add_hours(other, @today - back, 3600) }
    give_coins(other, 500)
    dashboard
    assert_select "article.dash-streak--empty", 2
    assert_select ".dash-coins strong", "0 coins"
  end

  # --- cost ---

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
