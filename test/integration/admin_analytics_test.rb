require "test_helper"
require_relative "../support/admin_sign_in"
require_relative "../support/ships_test_support"
require_relative "../support/shop_helper"

# /admin/analytics and its CSV and JSON (Analytics::Report): who can open it, what it shows, that small cells are hidden, that staff and
# simulated players move no number, and that nothing about a person is in any response.
class AdminAnalyticsTest < ActionDispatch::IntegrationTest
  include AdminSignIn
  include ShipsTestSupport
  include ShopTestHelper

  PERSONAL = { name: "Zed Zeppelin", email: "zed.zeppelin@example.org", uid: "ident!zedprivate", slack: "U0ZEDSLACK", idea: "a secret idea about llamas",
               profile: "zedzeppelinprofile" }.freeze

  setup do
    @admin = users(:onboarded)
  end

  def person(uid = "viz-#{SecureRandom.hex(4)}", **attrs) = User.create!({ hca_uid: uid, display_name: "Viz #{uid}" }.merge(attrs))

  def visit_with(steps = [], slug: nil, user: nil, referrer_kind: "direct", device_class: "desktop", at: Time.current)
    visit = AnalyticsVisit.create!(visit_key: SecureRandom.urlsafe_base64(16), started_at: at, referral_slug: slug, user: user, referrer_kind: referrer_kind, device_class: device_class)
    steps.each do |step|
      name, props = step.is_a?(Array) ? step : [ step, {} ]
      AnalyticsEvent.create!(name: name, props: props, occurred_at: at, visit: visit, user: user)
    end
    visit
  end

  def onboarding(*steps) = steps.map { |step| [ "onboarding_step_viewed", { "step" => step } ] }

  def rows_of(report, range: "7")
    get "/admin/analytics.json", params: { report: report, range: range }
    assert_response :success
    JSON.parse(response.body).fetch("rows")
  end

  test "signed-out visitors and non-admins get the same 404 as an unknown path, on the page, the downloads and the refresh" do
    get "/definitely-not-a-page"
    missing = response.body
    ENV["ADMIN_HCA_UIDS"] = "someone-else"
    [ nil, @admin ].each do |visitor|
      sign_in_as(visitor) if visitor
      [ "/admin/analytics", "/admin/analytics.csv?report=daily", "/admin/analytics.json?report=daily" ].each do |path|
        get path
        assert_response :not_found, "GET #{path} for #{visitor ? 'a non-admin' : 'a signed-out visitor'}"
        assert_equal missing, response.body if path == "/admin/analytics"
      end
      post "/admin/analytics/refresh"
      assert_response :not_found
    end
  end

  test "an admin sees every report on an empty database, in every period, with no script, inline style or outside asset" do
    as_admin(@admin)
    Analytics::Report::RANGES.each do |range|
      Analytics::Report::KEYS.each do |key|
        get "/admin/analytics", params: { range: range, report: key }
        assert_response :success
        assert_select "section##{key} h2"
        assert_select "nav[aria-label=Reports] a[aria-current=page]", text: Analytics::Report.label(key)
        assert_select "nav[aria-label=Period] a[aria-current=page]", text: range == "all" ? "All time" : "Last #{range} days"
      end
    end
    assert_select ".admin-page script", false
    assert_no_match(/\sstyle=|\sonclick=/, response.body)
    assert_equal "no-store", response.headers["Cache-Control"]
    get "/admin/analytics", params: { report: "daily" }
    assert_select "a[href*='report=daily']", minimum: 3 # the menu, CSV and JSON
  end

  test "the page builds only the report asked for, and an unknown one is the first" do
    as_admin(@admin)
    original = Analytics::Report.method(:fetch)
    asked = []
    stub_method(Analytics::Report, :fetch, ->(key, **options) { asked << key.to_s and original.call(key, **options) }) do
      get "/admin/analytics", params: { report: "events" }
      assert_equal %w[events], asked
      asked.clear
      get "/admin/analytics", params: { report: "nonsense" }
      assert_equal [ Analytics::Report::KEYS.first ], asked
    end
  end

  test "a report that runs past the statement limit says so instead of failing the page" do
    as_admin(@admin)
    slow = Object.new.tap { |sections| sections.define_singleton_method(:events) { raise ActiveRecord::QueryCanceled, "canceling statement due to statement timeout" } }
    stub_method(Analytics::Report::Sections, :new, ->(*) { slow }) do
      get "/admin/analytics", params: { report: "events", range: "all" }
    end
    assert_response :success
    assert_select "section#events .alert", text: /took longer than 20s/
  end

  test "an unknown period falls back to the default and the dashboard links to the page" do
    as_admin(@admin)
    get "/admin/analytics", params: { range: "9999" }
    assert_select "nav[aria-label=Period] a[aria-current=page]", text: "Last 7 days"
    get admin_root_path
    assert_select "a[href='#{admin_analytics_path}']", text: "Analytics"
  end

  test "the visitor funnel counts the visits that reached each step, conversion from the step before and from the first, and leaves staff and sims out" do
    full = [ "landing_viewed" ] + onboarding("age", "prize", "project", "schedule", "signup") + [ "signup_started", "signed_up" ]
    5.times { visit_with([ "landing_viewed" ]) }
    visit_with(onboarding("age", "prize"))
    visit_with([ "landing_viewed" ] + onboarding("age", "prize", "project", "schedule", "signup") + [ "signup_started" ])
    2.times { visit_with(full, user: person) }
    visit_with([ [ "onboarding_ineligible", {} ] ] + onboarding("age"))
    # Staff, a simulated player and a listed tester move nothing, even with a visit and events on file.
    visit_with(full, user: person("sim!funnel"))
    tester = person("tester-#{SecureRandom.hex(3)}")
    tester.update_columns(analytics_excluded: true)
    visit_with(full, user: tester)
    as_admin(@admin)
    visit_with(full, user: @admin)

    steps = rows_of("visits").index_by { |row| row["step"] }
    assert_equal [ 10, nil, 100.0 ], steps.fetch("Saw the landing page or onboarding").values_at("count", "percent_of_previous", "percent_of_first")
    assert_equal [ 5, 50.0, 50.0 ], steps.fetch("Onboarding, age step").values_at("count", "percent_of_previous", "percent_of_first")
    assert_equal [ 4, 80.0, 40.0 ], steps.fetch("Onboarding, prize step").values_at("count", "percent_of_previous", "percent_of_first")
    assert_equal 3, steps.fetch("Pressed sign up")["count"]
    assert_equal [ 2, 66.7, 20.0 ], steps.fetch("Signed up").values_at("count", "percent_of_previous", "percent_of_first")
    assert_equal 1, steps.fetch("Left: not a teen (answered the age question)")["count"]
  end

  test "the participant funnel shows what ParticipantFunnel returns: conversion from the step before and the first, hidden cells, steps counted on their own" do
    result = { filtered: true, total: 10,
               nested: [ { key: :signed_up, label: "Signed up", count: 10, kept_percent: 100.0, lost: 0 }, { key: :onboarded, label: "Onboarded", count: 8, kept_percent: 80.0, lost: 2 },
                         { key: :linked_hackatime, label: "Linked Hackatime", count: 5, kept_percent: 62.5, lost: 3 },
                         { key: :added_project, label: "Added a project with Hackatime", count: "<5", kept_percent: nil, lost: nil } ],
               ever_reached: [ { key: :signed_up, label: "Signed up", count: 10, kept_percent: 100.0, median_seconds: nil, timed: nil },
                               { key: :onboarded, label: "Onboarded", count: 8, kept_percent: 80.0, median_seconds: 600, timed: 8 },
                               { key: :linked_hackatime, label: "Linked Hackatime", count: 7, kept_percent: 70.0, median_seconds: 5400, timed: 7 },
                               { key: :added_project, label: "Added a project with Hackatime", count: "<5", kept_percent: nil, median_seconds: nil, timed: "<5" },
                               { key: :past_1h, label: "Past 1 hour", count: 3, kept_percent: 30.0, median_seconds: nil, timed: "<5" } ] }
    as_admin(@admin)
    received = []
    stub_method(ParticipantFunnel, :run, ->(**kwargs) { received << kwargs && result }) do
      travel_to Time.utc(2026, 11, 26, 12) do
        get "/admin/analytics.json", params: { report: "funnel", range: "30" }
        steps = JSON.parse(response.body).fetch("rows").index_by { |row| row["step"] }
        assert_equal [ 8, 80.0, 80.0, 2, 8, 0.2, 8 ], steps.fetch("Onboarded").values_at("count", "percent_of_previous", "percent_of_first", "lost", "reached", "median_hours_from_earlier_step", "timed")
        assert_equal [ 5, 62.5, 50.0, 3, 7, 1.5, 7 ], steps.fetch("Linked Hackatime").values_at("count", "percent_of_previous", "percent_of_first", "lost", "reached", "median_hours_from_earlier_step", "timed")
        assert_equal [ "<5", nil, nil, nil, "<5", "<5" ], steps.fetch("Added a project with Hackatime").values_at("count", "percent_of_previous", "percent_of_first", "lost", "reached", "timed")
        assert_equal [ nil, 3 ], steps.fetch("Past 1 hour").values_at("count", "reached")

        get "/admin/analytics.json", params: { report: "funnel", range: "all" }
      end
    end
    assert_equal [ { since: Date.new(2026, 10, 28), until: Date.new(2026, 11, 26) }, { since: nil, until: nil } ], received
  end

  test "the participant funnel, stuck and cohort tables count real people who signed up in the period, without staff and sims" do
    2.times { person }
    person("sim!funnel")
    as_admin(@admin)
    steps = rows_of("funnel").index_by { |row| row["step"] }
    assert_equal [ 2, 100.0 ], steps.fetch("Signed up").values_at("count", "percent_of_first")
    assert_equal "<5", steps.fetch("Onboarded")["count"]

    all = rows_of("funnel", range: "all").first
    assert_equal User.analytics_included.count, all["count"]

    stuck = rows_of("stuck", range: "all")
    assert_equal ParticipantFunnel::STAGES.size, stuck.size

    cohorts = rows_of("cohorts")
    assert_equal [ 2 ], cohorts.map { |row| row["people"] }
    assert_equal "<5", cohorts.first["day1_eligible"]
  end

  test "per-day numbers: visits, sign-ups, presence, active players, ships, approvals, purchases and boss damage, without sims" do
    travel_to Time.utc(2026, 11, 26, 12) do
      3.times { person }
      sim = person("sim!daily")
      AnalyticsSiteDay.create!(user: User.where.not(id: sim.id).order(:id).last, day: Date.new(2026, 11, 26))
      AnalyticsSiteDay.create!(user: sim, day: Date.new(2026, 11, 26))
      visit_with([ "landing_viewed" ])
      visit_with([ "landing_viewed" ], user: sim)
      teen = users(:new_user)
      teen.update_columns(onboarded_at: Time.utc(2026, 11, 2), onboarding_step: 4, created_at: Time.utc(2026, 11, 1, 12), signed_up_on: Date.new(2026, 11, 1))
      project = make_project(teen)
      code(teen, Date.new(2026, 11, 8), HOUR)
      ship = submit_ship(project)
      verified!(teen)
      give_coins(teen, 100)
      buy(teen, "keychain")
      ship.update_columns(status: "approved", reviewed_at: Time.current, approved_seconds: HOUR)
      simmed = person("sim!ships")
      simmed.update_columns(created_at: Time.current)
      as_admin(@admin)

      days = rows_of("daily", range: "30").index_by { |row| row["day"] }
      today = days.fetch("2026-11-26")
      assert_equal 3, today["signups"]
      assert_equal 1, today["visits"]
      assert_equal 1, today["site_people"]
      assert_equal [ 1, 1, 1, 1.0 ], today.values_at("ships_submitted", "ships_approved", "purchases", "boss_damage_hours")
      assert_equal [ 1, 1.0 ], days.fetch("2026-11-08").values_at("active_players", "hours_coded")
      assert_equal 1, days.fetch("2026-11-01")["signups"]
      assert_equal "2026-11-26", rows_of("daily", range: "7").first["day"]
      assert_equal 7, rows_of("daily", range: "7").size
    end
  end

  test "referral and source breakdowns hide cells under five, and the percentage with them, in the page and both downloads" do
    5.times { |index| visit_with([ "landing_viewed" ] + (index < 2 ? [ "signed_up" ] : []), slug: "haven", device_class: "mobile") }
    4.times { |index| visit_with([ "landing_viewed" ] + (index.zero? ? [ "signed_up" ] : []), slug: "terra", referrer_kind: "social") }
    as_admin(@admin)

    rows = rows_of("referrals").index_by { |row| [ row["breakdown"], row["value"] ] }
    assert_equal [ 5, "<5", nil ], rows.fetch([ "Referral link", "haven" ]).values_at("visits", "signed_up_visits", "conversion_percent")
    assert_equal [ "<5", "<5", nil ], rows.fetch([ "Referral link", "terra" ]).values_at("visits", "signed_up_visits", "conversion_percent")
    assert_equal "<5", rows.fetch([ "Came from", "social" ])["visits"]
    assert_equal 5, rows.fetch([ "Device", "mobile" ])["visits"]

    get "/admin/analytics.csv", params: { report: "referrals" }
    terra = CSV.parse(response.body, headers: true).find { |row| row["value"] == "terra" }
    assert_equal "<5", terra["visits"]
    get "/admin/analytics", params: { report: "referrals" }
    assert_select "section#referrals td", text: "<5"
    assert_no_match(/terra.{0,200}>4</m, css_select("section#referrals").to_s)
  end

  test "events lists every allowlisted event, shows hooks with no rows, hides small counts and leaves staff out" do
    6.times { AnalyticsEvent.create!(name: "landing_viewed", occurred_at: 2.hours.ago) }
    3.times { AnalyticsEvent.create!(name: "streak_broken", occurred_at: 3.days.ago, user: person, props: { "days_bucket" => "1" }) }
    AnalyticsEvent.create!(name: "landing_viewed", occurred_at: 1.hour.ago, user: person("sim!events"))
    AnalyticsEvent.create!(name: "ship_form_viewed", occurred_at: 40.days.ago)
    as_admin(@admin)

    rows = rows_of("events").index_by { |row| row["event"] }
    assert_equal Analytics::Events.names.sort, rows.keys.sort
    assert_equal [ 6, 6, "recorded" ], rows.fetch("landing_viewed").values_at("in_range", "last_24_hours", "wired")
    assert_equal [ "<5", 0, "recorded" ], rows.fetch("streak_broken").values_at("in_range", "last_24_hours", "wired")
    assert_equal [ 0, nil, "none yet" ], rows.fetch("ship_submitted").values_at("in_range", "last_seen", "wired")
    assert_equal "none yet", rows.fetch("ship_form_viewed")["wired"]
    assert_equal "recorded", rows_of("events", range: "all").find { |row| row["event"] == "ship_form_viewed" }["wired"]
  end

  test "job health: last run, last success, failed, stale in words and red, never run, off by flag, and a job outside the schedule" do
    JobRun.create!(name: "game:settle", started_at: 5.minutes.ago, finished_at: 4.minutes.ago, status: "ok")
    JobRun.create!(name: "hackatime:sync", started_at: 3.hours.ago, finished_at: 3.hours.ago, status: "ok")
    JobRun.create!(name: "hackatime:sync", started_at: 20.minutes.ago, finished_at: 19.minutes.ago, status: "failed", error_class: "Net::ReadTimeout")
    JobRun.create!(name: "notifications:dispatch", started_at: 3.minutes.ago, finished_at: 2.minutes.ago, status: "ok")
    JobRun.create!(name: "notifications:dispatch", started_at: 1.minute.ago, finished_at: 1.minute.ago, status: "failed", error_class: "Timeout::Error")
    JobRun.create!(name: "extra:thing", started_at: 1.hour.ago, finished_at: 1.hour.ago, status: "ok")
    as_admin(@admin)

    rows = rows_of("jobs").index_by { |row| row["job"] }
    assert_equal (JobSchedule.jobs.keys + [ "extra:thing" ]).sort, rows.keys.sort
    assert_equal "ok", rows.fetch("game:settle")["status"]
    assert_equal 60, rows.fetch("game:settle")["expected_every_minutes"]
    assert_equal "stale", rows.fetch("hackatime:sync")["status"]
    assert_match(/Stale: no successful run for about 3 hours \(expected every 60 minutes\)/, rows.fetch("hackatime:sync")["detail"])
    assert_equal "Net::ReadTimeout", rows.fetch("hackatime:sync")["last_error"]
    assert_equal "failed", rows.fetch("notifications:dispatch")["status"]
    assert_equal "never_run", rows.fetch("orders:purge_addresses")["status"]
    assert_nil rows.fetch("orders:purge_addresses")["last_run"]
    assert_equal "off", rows.fetch("quests:evaluate")["status"]
    assert_equal [ "unscheduled", nil ], rows.fetch("extra:thing").values_at("status", "expected_every_minutes")

    get "/admin/analytics", params: { report: "jobs" }
    assert_select "section#jobs tr", text: /hackatime:sync/ do
      assert_select ".badge--danger", text: "Stale"
    end
    assert_select "section#jobs tr", text: /orders:purge_addresses/ do
      assert_select ".badge--danger", text: "Never run"
    end
    assert_select "section#jobs tr", text: /game:settle/ do
      assert_select ".badge--success", text: "Ran fine"
    end
  end

  test "table sizes: every analytics table, with its rows, new rows and sizes" do
    3.times { visit_with([ "landing_viewed" ]) }
    visit_with([ "landing_viewed" ], at: 5.days.ago)
    as_admin(@admin)

    rows = rows_of("tables").index_by { |row| row["table"] }
    assert_equal %w[analytics_daily_snapshots analytics_events analytics_site_days analytics_visits job_runs], rows.keys.sort
    assert_equal [ 4, 3 ], rows.fetch("analytics_visits").values_at("rows", "new_rows_24_hours") # the five-day-old one is not new
    assert_equal 4, rows.fetch("analytics_events")["rows"]
    assert_equal 0, rows.fetch("job_runs")["rows"]
    assert(rows.values.all? { |row| row["total_bytes"].positive? && row["total_bytes"] >= row["table_bytes"] })
    get "/admin/analytics", params: { report: "tables" }
    assert_select "section#tables th[scope=row]", text: "analytics_events"
  end

  test "downloads: a CSV and a JSON of each report with the same columns and rows as the page, as attachments" do
    visit_with([ "landing_viewed" ] + onboarding("age"))
    as_admin(@admin)
    Analytics::Report::KEYS.each do |key|
      get "/admin/analytics.csv", params: { report: key, range: "30" }
      assert_response :success
      assert_equal "text/csv; charset=utf-8", response.headers["Content-Type"]
      assert_match(/\Aattachment; filename="battletown-analytics-#{key}-30-\d{4}-\d\d-\d\d\.csv"/, response.headers["Content-Disposition"])
      csv = CSV.parse(response.body, headers: true)
      table = Analytics::Report.fetch(key, range: "30")
      assert_equal table.columns.map { |column| column.key.to_s }, csv.headers
      assert_equal table.rows.size, csv.size

      get "/admin/analytics.json", params: { report: key, range: "30" }
      assert_response :success
      assert_match(/\Aattachment; filename=".+\.json"/, response.headers["Content-Disposition"])
      json = JSON.parse(response.body)
      assert_equal [ key, "30" ], json.values_at("report", "range")
      assert_equal csv.headers, json["columns"].map { |column| column["key"] }
      assert_equal table.rows.size, json["rows"].size
    end
  end

  test "a download for a missing or unknown report is the same 404 as a missing page" do
    as_admin(@admin)
    [ {}, { report: "users" }, { report: "daily; drop table users" } ].each do |params|
      get "/admin/analytics.csv", params: params
      assert_response :not_found
      get "/admin/analytics.json", params: params
      assert_response :not_found
    end
  end

  test "the refresh button drops the cached numbers (and only those)" do
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    as_admin(@admin)
    visit_with([ "landing_viewed" ])
    assert_equal 1, rows_of("visits").first["count"]
    visit_with([ "landing_viewed" ])
    assert_equal 1, rows_of("visits").first["count"], "cached for five minutes"
    assert_no_difference -> { AnalyticsVisit.count } do
      post "/admin/analytics/refresh", params: { range: "30" }
    end
    assert_redirected_to "/admin/analytics?range=30"
    assert_equal 2, rows_of("visits").first["count"]
  ensure
    Rails.cache = original
  end

  test "refresh is not audited and writes no audit row" do
    as_admin(@admin)
    assert_no_difference -> { AdminAuditEvent.count } do
      post "/admin/analytics/refresh", params: { report: "events" }
      assert_redirected_to admin_analytics_path(range: "7", report: "events")
      get "/admin/analytics"
    end
  end

  test "no response carries anything about a person: no name, email, uid, Slack id, idea or id column" do
    zed = person(PERSONAL[:uid], display_name: PERSONAL[:name], email: PERSONAL[:email], slack_id: PERSONAL[:slack], project_idea: PERSONAL[:idea],
                 profile_name: PERSONAL[:profile])
    visit = visit_with([ "landing_viewed", "signed_up" ] + onboarding("age"), slug: "haven", user: zed)
    AnalyticsEvent.create!(name: "ship_submitted", props: { "hours_bucket" => "1-2", "nth" => "1", "after_rejection" => false }, occurred_at: Time.current, user: zed)
    AnalyticsSiteDay.create!(user: zed, day: Time.current.utc.to_date)
    HourEntry.create!(user: zed, local_date: Time.current.utc.to_date, seconds: 1200, source: "manual", note: PERSONAL[:idea], idempotency_key: "zed-1")
    JobRun.create!(name: "game:settle", started_at: 1.minute.ago, status: "ok", counts: { "users" => 1 })
    as_admin(@admin)

    banned_columns = /(\Aid\z|_id\z|email|display_name|slack|hca|uid|user|person|token|address|agent|\bip\b|idea|note|comment)/
    bodies = []
    Analytics::Report::RANGES.each do |range|
      Analytics::Report::KEYS.each do |key|
        get "/admin/analytics", params: { range: range, report: key }
        bodies << response.body
        get "/admin/analytics.csv", params: { report: key, range: range }
        bodies << response.body
        assert_no_match banned_columns, CSV.parse(response.body).first.join(","), "CSV columns of #{key}"
        get "/admin/analytics.json", params: { report: key, range: range }
        bodies << response.body
        assert_no_match banned_columns, JSON.parse(response.body).fetch("columns").map { |column| column["key"] }.join(","), "JSON columns of #{key}"
      end
    end
    bodies.each do |body|
      PERSONAL.each_value { |value| assert_not_includes body, value }
      assert_not_includes body, visit.visit_key
      assert_not_includes body, zed.analytics_id
    end
    assert(bodies.any? { |body| body.include?("haven") }, "the slug is a channel, not a person")
  end
end
