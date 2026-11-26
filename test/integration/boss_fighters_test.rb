require "test_helper"
require_relative "../support/fighters_helper"
require_relative "../support/profiles_helper"

# GET /boss/fighters: the live stage's JSON (boss_fighters_controller.js polls it).
class BossFightersEndpointTest < ActionDispatch::IntegrationTest
  include FightersHelper
  include ProfilesHelper

  # Throttle keys are Time.now.to_i / period: freeze time at the start of a window so the 13 requests share one.
  WINDOW_START = Time.utc(2030, 1, 1, 12, 0, 0)

  setup do
    @user = users(:onboarded)
    @today = Time.current.utc.to_date
    @user.update_columns(created_at: (@today - 30).in_time_zone("UTC"), signed_up_on: @today - 30)
    @boss = make_boss(starts_on: friday_on_or_before(@today), hp_seconds: 100 * HOUR)
  end

  teardown { reset_omniauth }

  def live(key, **args) = fighter(key, now: Time.current, **args)

  def json = JSON.parse(response.body)

  def count_queries
    count = 0
    counter = ->(*, payload) { count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) || payload[:sql].match?(/\A\s*(BEGIN|COMMIT|SAVEPOINT|RELEASE)/i) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end

  test "signed out goes home, not onboarded goes to onboarding" do
    get boss_fighters_path
    assert_redirected_to root_path

    sign_in_as users(:new_user)
    get boss_fighters_path
    assert_redirected_to onboarding_path
  end

  test "only GET exists" do
    sign_in_as @user
    post boss_fighters_path
    assert_response :not_found
  end

  test "the shape: the boss, the health, the sentences, the counts and the circles' public bits" do
    ada = live("ada", seconds: 7200, name: "Ada")
    ship_damage(ada, 3600 * 10, on: Time.current)
    closed = live("closed", seconds: 1800)
    sign_in_as @user
    get boss_fighters_path

    assert_response :success
    assert_equal "application/json", response.media_type
    assert_includes response.headers["Cache-Control"], "private"
    assert_equal %w[arena_text boss_name damage_text fighters health_percent health_text shippers state summary total], json.keys.sort
    assert_equal [ "in_progress", @boss.name, 90, "90% left", 2, 1 ], json.values_at("state", "boss_name", "health_percent", "health_text", "total", "shippers")
    assert_match(/2 people coded in the last day\. 1 of them shipped\./, json["arena_text"])
    assert_match(/Boss at 90% health/, json["summary"])
    assert_equal "Ship a project to land your first hit.", json["damage_text"]

    named, other = json["fighters"]
    assert_equal %w[avatar_url detail hint initial key label motion name path size status title tone tier you].sort, named.keys.sort
    assert_equal [ "Ada", "Ada", "A", "ship", 4, "/players/#{ada.public_slug}", false ], named.values_at("name", "title", "initial", "tier", "size", "path", "you")
    assert_equal "Ada: coded about 2 h in the last day, shipped a project: hit the boss. Click to see their profile.", named["label"]
    handle = PublicProfile.handle_for(closed.public_slug)
    assert_equal [ handle, handle.first, "/players/#{closed.public_slug}", "idle", "Click to see their profile" ], other.values_at("name", "initial", "path", "tier", "hint")
    assert_kind_of Integer, other["tone"]
  end

  test "each circle's own rhythm is in it, fixed by its key and the same on every poll" do
    10.times { |index| live("mover#{index}", seconds: 1800 + index) }
    sign_in_as @user
    get boss_fighters_path
    first = json["fighters"].to_h { |fighter| [ fighter["key"], fighter["motion"] ] }
    get boss_fighters_path
    again = json["fighters"].to_h { |fighter| [ fighter["key"], fighter["motion"] ] }

    assert_equal 10, first.size
    assert_equal first, again, "the same person keeps the same rhythm"
    first.each do |key, motion|
      assert_equal Bosses::FighterMotion.for_key(key).stringify_keys, motion
      assert_equal Bosses::FighterMotion::STEPS.keys.map(&:to_s), motion.keys
    end
    assert_equal 10, first.values.uniq.size, "nobody moves like anybody else"
  end

  test "no ids, emails, real names, Slack ids or exact minutes are in it" do
    ada = live("ada", seconds: 7260, name: "Ada")
    other = live("closed", seconds: 1860)
    sign_in_as @user
    get boss_fighters_path

    [ "private.example.org", "Real Name", "SLK", "ident!", ada.hca_uid, ada.slack_id, other.slack_id, ada.email, "\"#{ada.id}\"", "\"#{other.id}\"" ].each do |secret|
      assert_not_includes response.body, secret
    end
    # Exact minutes as whole numbers only: a random key or address can contain "31" or "121" inside its letters and digits.
    %w[7260 121 1860 31].each { |number| assert_no_match(/(?<![\w])#{number}(?![\w])/, response.body, "the number #{number} shows up") }
    assert_not_includes json["fighters"].flat_map(&:values).map(&:to_s), @user.id.to_s
  end

  test "your own circle is marked, and only in your own answer" do
    @user.update!(profile_name: "Me")
    code_ago(@user, 3600, now: Time.current)
    live("other", seconds: 1800)
    sign_in_as @user
    get boss_fighters_path

    mine = json["fighters"].find { |circle| circle["you"] }
    assert_equal "You (Me)", mine["title"]
    assert_equal 1, json["fighters"].count { |circle| circle["you"] }
  end

  test "nobody coded: no circles, and the arena sentence says so (no separate visible text)" do
    sign_in_as @user
    get boss_fighters_path

    assert_equal [ [], 0, 0 ], json.values_at("fighters", "total", "shippers")
    assert_not json.key?("quiet_text")
    assert_match(/\ANobody has coded in the last day\. Be the first to hit it\./, json["arena_text"])
  end

  test "between bosses it still answers, with state none" do
    @boss.destroy
    sign_in_as @user
    get boss_fighters_path

    assert_response :success
    assert_equal "none", json["state"]
  end

  test "an unchanged answer is a bodyless 304 by ETag, a changed one is a new 200" do
    live("first", seconds: 1800, name: "Ada")
    sign_in_as @user
    get boss_fighters_path
    etag = response.headers["ETag"]
    assert_predicate etag, :present?

    get boss_fighters_path, headers: { "If-None-Match" => etag }
    assert_response :not_modified
    assert_empty response.body

    live("second", seconds: 1800)
    get boss_fighters_path, headers: { "If-None-Match" => etag }
    assert_response :success
    assert_not_equal etag, response.headers["ETag"]
    assert_equal 2, json["total"]
  end

  test "the answer is per person: another player has another ETag" do
    @user.update!(profile_name: "Me")
    code_ago(@user, 1800, now: Time.current)
    sign_in_as @user
    get boss_fighters_path
    mine = response.headers["ETag"]

    other = live("other", seconds: 1800, name: "Zed")
    sign_in_as other
    get boss_fighters_path
    assert_not_equal mine, response.headers["ETag"]
    assert_equal [ "Zed" ], json["fighters"].select { |circle| circle["you"] }.pluck("title").map { |title| title[/\((.+)\)/, 1] }
  end

  test "a bounded number of queries however many people coded" do
    sign_in_as @user
    get boss_fighters_path
    baseline = count_queries { get boss_fighters_path }

    20.times { |index| live("many#{index}", seconds: 1800 + index) }
    more = count_queries { get boss_fighters_path }
    assert_operator more, :<=, baseline, "baseline #{baseline}, with 20 people #{more}"
  end

  # --- the throttle: 12 a minute per signed-in person ---

  test "12 requests a minute per person, then 429 with a JSON body and Retry-After; another person has their own allowance" do
    other = live("throttle-other", seconds: nil)
    travel_to WINDOW_START do
      sign_in_as @user
      Rack::Attack.enabled = true
      Rack::Attack.cache.store.clear
      12.times do
        get boss_fighters_path
        assert_response :success
      end
      get boss_fighters_path, headers: { "Accept" => "application/json" }
      assert_response :too_many_requests
      assert_equal "rate_limited", json["error"]
      assert_predicate response.headers["Retry-After"], :present?

      sign_in_as other
      get boss_fighters_path
      assert_response :success
    end
  ensure
    Rack::Attack.cache.store.clear
    Rack::Attack.enabled = false
  end
end
