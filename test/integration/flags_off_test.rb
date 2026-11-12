require "test_helper"
require_relative "../support/ships_test_support"
require_relative "../support/shop_helper"
require_relative "../support/bosses_helper"

# The production default: every flag OFF. The app must look and cost exactly what it did before the nine flagged features
# existed: no flagged route, no flagged link or card or switch, no query on a flagged table, no row, no background work.
# These are the cross-feature checks (each feature also tests its own off state); they read the router, so a flagged route
# added later is covered, and one added outside its constraint fails.
class FlagsOffTest < ActionDispatch::IntegrationTest
  include ShipsTestSupport
  include ShopTestHelper
  include BossesHelper

  # Every route that exists only while its flag is on, as the router draws them: [verb, path]. The two flags without routes
  # (`returning`, `eligibility_gate`) change behaviour of existing pages only. A new flagged route must be listed here.
  FLAG_ROUTES = {
    team: [ %w[GET /team], %w[POST /team], %w[PATCH /team], %w[PUT /team], %w[POST /team/invite], %w[DELETE /team/leave],
            %w[GET /team/join/:token], %w[POST /team/join/:token], %w[GET /admin/teams], %w[DELETE /admin/teams/:id] ],
    quests: [ %w[GET /admin/quests], %w[POST /admin/quests], %w[GET /admin/quests/new], %w[GET /admin/quests/:id/edit],
              %w[PATCH /admin/quests/:id], %w[PUT /admin/quests/:id] ],
    returning: [],
    plinko: [ %w[GET /plinko], %w[PATCH /plinko/leaderboard], %w[POST /plinko/nickname], %w[POST /plinko/drops], %w[GET /admin/plinko] ],
    ship_screenshots: [ %w[GET /ships/:ship_id/images/:position], %w[DELETE /admin/ships/:ship_id/images/:position] ],
    merch_track: [ %w[GET /merch], %w[POST /merch/weeks/:boss_id/claim], %w[GET /admin/merch], %w[PATCH /admin/merch/:id/fulfill],
                   %w[PATCH /admin/merch/:id/cancel] ],
    email: [ %w[GET /email/unsubscribe/:token], %w[POST /email/unsubscribe/:token], %w[GET /admin/email] ],
    nps: [ %w[GET /feedback/:token], %w[POST /feedback/:token], %w[GET /admin/nps], %w[POST /admin/nps/:id/reveal] ],
    eligibility_gate: []
  }.freeze

  # Controllers that belong to a flagged feature: every route they have must sit inside that flag's constraint.
  FLAGGED_CONTROLLERS = {
    "teams" => :team, "team_joins" => :team, "admin/teams" => :team, "admin/quests" => :quests, "plinko" => :plinko,
    "plinko_drops" => :plinko, "admin/plinko" => :plinko, "ship_images" => :ship_screenshots, "admin/ship_images" => :ship_screenshots,
    "merch" => :merch_track, "merch_claims" => :merch_track, "admin/merch_claims" => :merch_track, "email_unsubscribes" => :email,
    "admin/email_notifications" => :email, "feedback" => :nps, "admin/nps" => :nps
  }.freeze

  # Tables only a flagged feature reads or writes. A flags-off page must never query one (so costs nothing and exposes nothing).
  FLAGGED_TABLES = %w[merch_claims plinko_drops plinko_players quests quest_completions teams team_memberships team_payouts team_cooldowns
                      welcome_back_windows ship_images nps_responses staff_access_logs].freeze

  setup do
    OmniAuth.config.test_mode = true
    @original_admins = ENV["ADMIN_HCA_UIDS"]
    @detailed = Rails.application.env_config["action_dispatch.show_detailed_exceptions"]
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = false
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = @detailed
    @original_admins.nil? ? ENV.delete("ADMIN_HCA_UIDS") : ENV["ADMIN_HCA_UIDS"] = @original_admins
  end

  def sign_in_as(user)
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
  end

  def flag_guards(route)
    constraints = route.app.respond_to?(:constraints) ? route.app.constraints : []
    constraints.grep(Features::Constraint).map(&:name)
  end

  def router_paths(route)
    path = route.path.spec.to_s.sub("(.:format)", "")
    route.verb.to_s.split("|").map { |verb| [ verb.gsub(/[^A-Z]/, ""), path ] }.reject { |verb, _| verb.empty? }
  end

  def table_counts
    ActiveRecord::Base.connection.tables.sort.to_h { |table| [ table, ActiveRecord::Base.connection.select_value("SELECT count(*) FROM #{table}").to_i ] }
  end

  # The SQL a block runs, minus transaction and schema noise.
  def sql_of
    statements = []
    recorder = lambda do |*, payload|
      next if %w[SCHEMA TRANSACTION].include?(payload[:name]) || payload[:sql].match?(/\A\s*(BEGIN|COMMIT|SAVEPOINT|RELEASE)/i)

      statements << payload[:sql]
    end
    ActiveSupport::Notifications.subscribed(recorder, "sql.active_record") { yield }
    statements
  end

  def touches_flagged_table?(sql) = FLAGGED_TABLES.any? { |table| sql.match?(/\b(FROM|JOIN|INTO|UPDATE)\s+"#{table}"/i) }

  # --- the router ---

  test "the router's flagged routes are exactly the documented ones, and every flag is accounted for" do
    found = Hash.new { |hash, flag| hash[flag] = [] }
    Rails.application.routes.routes.each do |route|
      flag_guards(route).each { |flag| found[flag].concat(router_paths(route)) }
    end

    FLAG_ROUTES.each { |flag, expected| assert_equal expected.sort, found[flag].sort, "routes behind #{flag} changed: list them in FLAG_ROUTES" }
    assert_equal Features::NAMES.sort, FLAG_ROUTES.keys.sort, "a new flag needs an entry here (an empty list if it has no routes)"
  end

  test "no route of a flagged feature's controllers sits outside its flag" do
    Rails.application.routes.routes.each do |route|
      flag = FLAGGED_CONTROLLERS[route.defaults[:controller].to_s]
      next unless flag

      assert_equal [ flag ], flag_guards(route), "#{route.verb} #{route.path.spec} (#{route.defaults[:controller]}) must be inside Features::Constraint.new(:#{flag})"
    end
  end

  test "with every flag off each flagged route is a plain 404 for the signed-out, a teen and an admin, whatever the verb, and writes nothing" do
    ENV["ADMIN_HCA_UIDS"] = users(:onboarded).hca_uid
    Features::NAMES.each { |name| assert_not Features.enabled?(name), "#{name} must default to off" }
    before = table_counts

    paths = FLAG_ROUTES.values.flatten(1).map { |verb, path| [ verb, path.gsub(/:token/, "a" * 24).gsub(/:\w+/, "1") ] }.uniq
    assert_operator paths.size, :>=, 30
    [ nil, users(:new_user), users(:onboarded) ].each do |visitor|
      delete logout_path if visitor
      sign_in_as(visitor) if visitor
      paths.each do |verb, path|
        process(verb.downcase.to_sym, path)
        assert_response :not_found, "#{verb} #{path} must be a 404 with its flag off (visitor: #{visitor&.display_name || 'signed out'})"
      end
    end
    assert_equal before.except("sessions"), table_counts.except("sessions"), "a flagged route wrote something while off"
  end

  # --- pages ---

  def fill_world
    @teen = users(:onboarded)
    @today = Hours::Days.today(@teen)
    @teen.update_columns(created_at: (@today - 30).in_time_zone("UTC"), signed_up_on: @today - 30, slack_id: "U0TEEN0001")
    make_boss(starts_on: @today.beginning_of_week(:friday), hp_seconds: 100 * HOUR)
    @project = make_project(@teen)
    (1..4).each { |back| code(@teen, @today - back, 3600) }
    @ship = submit_ship(@project)
    @second = make_project(@teen, name: "Second", hackatime: "second")
    code(@teen, @today - 1, 3600, hackatime: "second")
    verified!(@teen)
    give_coins(@teen, 50)
  end

  test "with every flag off, no page of a signed-in teen or of staff reads a flagged table, and none shows flagged copy" do
    fill_world
    admin = users(:new_user)
    admin.update_columns(onboarded_at: Time.current, onboarding_step: 4)
    ENV["ADMIN_HCA_UIDS"] = admin.hca_uid

    sign_in_as @teen
    teen_pages = [ dashboard_path, projects_path, ships_path, ship_path(@ship), shop_path, settings_notifications_path, hackatime_path, new_project_ship_path(@second) ]
    forbidden = /Plinko|Weekly quest|Your crew|crew|Welcome back|merch track|Merch|screenshot|Screenshot|survey|NPS|YSWS eligible/
    teen_pages.each do |path|
      statements = sql_of { get path }
      assert_response :success, path
      assert_empty statements.select { |sql| touches_flagged_table?(sql) }, "#{path} queried a flagged table with every flag off"
      assert_no_match forbidden, response.body.gsub(/<script.*?<\/script>|<style.*?<\/style>/m, ""), "#{path} shows flagged copy"
      assert_select "form[enctype='multipart/form-data']", 0, "#{path} must not become a file-upload form"
    end

    delete logout_path
    sign_in_as admin
    [ admin_root_path, admin_ships_path, admin_ship_path(@ship), admin_orders_path, admin_bosses_path, admin_metrics_path ].each do |path|
      statements = sql_of { get path }
      assert_response :success, path
      assert_empty statements.select { |sql| touches_flagged_table?(sql) }, "#{path} queried a flagged table with every flag off"
      assert_no_match(/Plinko|Crews|NPS|Weekly quests|Merch claims|Email rows/, response.body, "#{path} links to a flagged page")
    end
  end

  test "with every flag off the header navigation and settings menu hold only the original links" do
    fill_world
    sign_in_as @teen
    get dashboard_path
    labels = css_select("nav.site-header__nav a").map { |link| link.text.strip }
    assert_equal %w[Dashboard Projects Ships Shop Hackatime Notifications], labels
    assert_select "nav a[href='/plinko'], nav a[href='/team'], nav a[href='/merch']", 0
  end

  test "with every flag off the notification settings page lists only the original Slack switches and no email section" do
    fill_world
    sign_in_as @teen
    get settings_notifications_path
    assert_response :success
    kinds = css_select("input[type=checkbox][name^='preferences[']").map { |box| box["name"][/\[(.+)\]/, 1] }
    assert_equal %w[daily_reminder link_question ship_reminder ship_mvp ship_approved ship_rejected], kinds
    assert_select "#email-settings", 0
    assert_select "input[name=email_enabled]", 0

    patch settings_notifications_path, params: { preferences: { nps_prompt: "0", returning_nudge: "0", ship_approved: "0" }, email_enabled: "0" }
    assert_equal 1, NotificationPreference.where(user_id: @teen.id).count, "only a visible kind can be changed"
    assert_nil @teen.reload.email_opted_out_at, "the email switch is ignored with the flag off"
  end

  test "the dashboard query count with every flag off is the pre-feature bound" do
    fill_world
    sign_in_as @teen
    get dashboard_path
    count = sql_of { get dashboard_path }.size
    assert_operator count, :<=, 30, "dashboard ran #{count} queries" # DashboardTest::QUERY_BOUND, the bound before the flagged features
  end

  # --- work ---

  test "with every flag off approving a ship, settling and the scans create no flagged rows, mail or jobs" do
    fill_world
    reviewer = users(:new_user)
    reviewer.update_columns(onboarded_at: Time.current, onboarding_step: 4)
    before = table_counts

    assert_no_enqueued_jobs do
      assert_emails 0 do
        result = Ships::Approve.call(ship: @ship, reviewer: reviewer, approved_seconds: @ship.coded_seconds)
        assert result.approved?
        Game::Settle.call(@teen)
        assert_equal 0, Teams::PayPending.scan.scanned
        assert_equal({ users: 0, completions: 0, errors: 0 }, Quests::Evaluate.all)
        assert_equal 0, Notifications::NpsPrompts.call.to_h.values.sum { |value| value.is_a?(Integer) ? value : 0 } if Notifications::NpsPrompts.respond_to?(:call)
      end
    end

    after = table_counts
    FLAGGED_TABLES.each { |table| assert_equal before[table], after[table], "#{table} changed with every flag off" }
    assert_equal %w[ship_approval], CoinTransaction.where(user_id: @teen.id, reference_type: "Ship").pluck(:kind).uniq - %w[streak_bonus]
    assert_empty Notification.where(channel: "email")
    assert_empty Notification.where(kind: %w[returning_nudge nps_prompt])
  end
end
