require "test_helper"
require_relative "../support/every_table_rows"

# The read-only `insights` views (db/insights/views.sql.erb, plans/analytics.md section 3): the exact public contract, nothing personal in any
# column or value, staff and simulated players excluded INSIDE the views, and a deleted person gone from them.
class InsightsViewsTest < ActiveSupport::TestCase
  include EveryTableRows

  PUBLIC_VIEWS = %w[coin_transactions daily_results events funnel_facts hour_days notifications nps orders people projects review_actions_daily settings ships
                    site_days visits].freeze
  PRIVATE_VIEWS = %w[people].freeze
  # Column-name words that would mean personal data. A column is checked word by word (split on "_").
  BANNED_WORDS = %w[email display name slack hca uid address phone birth ip agent token secret password comment body note idea repo demo description reason zone
                    user users].freeze
  # "view.column" => why a banned word is fine: the name of an event, and booleans that only say something exists (never what it is).
  REVIEWED = { "events.name" => "the event name, a catalogue key", "people.has_idea" => "true or false, never the idea",
               "projects.has_repo" => "true or false, never the URL", "projects.has_demo" => "true or false, never the URL" }.freeze

  setup do
    @original = ENV.values_at("ADMIN_HCA_UIDS", "ANALYTICS_EXCLUDE_HCA_UIDS")
    ENV.delete("ADMIN_HCA_UIDS")
    ENV.delete("ANALYTICS_EXCLUDE_HCA_UIDS")
  end

  teardown do
    ENV["ADMIN_HCA_UIDS"] = @original.first
    ENV["ANALYTICS_EXCLUDE_HCA_UIDS"] = @original.last
    ENV.delete("ADMIN_HCA_UIDS") if @original.first.nil?
    ENV.delete("ANALYTICS_EXCLUDE_HCA_UIDS") if @original.last.nil?
  end

  def connection = ActiveRecord::Base.connection

  def person_ids(view) = connection.select_values("SELECT person_id FROM insights.#{view} WHERE person_id IS NOT NULL")

  def analytics_id(user) = User.where(id: user.id).pick(:analytics_id)

  test "the public views are exactly the reviewed list" do
    assert_equal PUBLIC_VIEWS.sort, Analytics::Views.names
    assert_equal PRIVATE_VIEWS.sort, Analytics::Views.names("insights_private")
  end

  test "no public column is named like personal data, and none is a user id" do
    Analytics::Views.columns.each do |view, column, _type|
      next if REVIEWED.key?("#{view}.#{column}")

      assert_empty column.split("_") & BANNED_WORDS, "insights.#{view}.#{column} looks personal"
      assert_not_includes %w[id user_id], column, "insights.#{view} exposes #{column}"
    end
  end

  test "every person reference is a random uuid, not a user id" do
    columns = Analytics::Views.columns
    assert_equal "uuid", columns.find { |view, column, _| view == "people" && column == "person_id" }.last
    columns.select { |_, column, _| column == "person_id" }.each { |view, _, type| assert_equal "uuid", type, "insights.#{view}.person_id" }
    users(:onboarded).tap { |user| assert_not_equal user.id.to_s, analytics_id(user).to_s }
  end

  test "the private helper schema is not readable by anyone but the owner" do
    assert_nil connection.select_value("SELECT nspacl::text FROM pg_namespace WHERE nspname = 'insights_private'")
  end

  test "settings equal the game's configuration" do
    row = connection.select_one("SELECT * FROM insights.settings")
    assert_equal Hours::Config.current.days_before_signup_counted, row["days_before_signup_counted"]
    assert_equal Game::Config.current.quick_seconds, row["quick_seconds"]
    assert_equal ParticipantFunnel::HOUR_MARKS, connection.columns("insights.funnel_facts").filter_map { |c| c.name[/\Apast_(\d+)h_on\z/, 1]&.to_i }.sort
  end

  test "the views are current: a changed file or setting is noticed" do
    assert_predicate Analytics::Views, :current?
    connection.execute("COMMENT ON SCHEMA insights IS 'sha256:stale'")
    assert_not_predicate Analytics::Views, :current?
    assert Analytics::Views.ensure_current!, "a stale checksum is rebuilt"
    assert_predicate Analytics::Views, :current?
    assert_not Analytics::Views.ensure_current!, "a current one is left alone"
    assert_equal PUBLIC_VIEWS.sort, Analytics::Views.names
  end

  test "views are rebuilt inside the test transaction without losing data" do
    before = User.count
    Analytics::Views.rebuild!
    assert_equal before, User.count
    assert_equal User.analytics_included.count, connection.select_value("SELECT COUNT(*) FROM insights.people")
  end

  test "a person with a row in every table shows up as person_id only, with no personal value anywhere" do
    user = user_with_rows_in_every_table
    user.update_columns(slack_id: "ULEAKSLACK1", project_idea: "LEAKIDEAWORDS", time_zone: "Pacific/Auckland", referral_source: "other", display_name: "Leaky McLeakface")
    NpsResponse.where(user_id: user.id).update_all(comment: "LEAKCOMMENT")
    Ship.where(user_id: user.id).update_all(description: "LEAKSHIPTEXT", repo_url: "https://github.com/leakowner/leakrepo")
    Project.where(user_id: user.id).update_all(idea: "LEAKPROJECTIDEA", repo_url: "https://github.com/leakowner/leakrepo", demo_url: "https://leakdemo.example/x")
    Order.where(user_id: user.id).update_all(prize_name: "LEAKPRIZENAME")
    OrderEvent.where(note: "guard").update_all(note: "LEAKORDERNOTE")
    AnalyticsEvent.create!(name: "landing_viewed", user: user, occurred_at: Time.current)

    dump = PUBLIC_VIEWS.map { |view| "#{view}: #{connection.select_values("SELECT row_to_json(v)::text FROM insights.#{view} v").join("\n")}" }.join("\n")

    assert_includes dump, analytics_id(user), "the person is in the views under their random id"
    [ user.email, user.display_name, user.hca_uid, "Leaky McLeakface", "ULEAKSLACK1", "LEAKIDEAWORDS", "Pacific/Auckland", "LEAKCOMMENT", "LEAKSHIPTEXT", "leakowner", "LEAKPROJECTIDEA",
      "leakdemo", "LEAKPRIZENAME", "LEAKORDERNOTE", "Guard Person", "1 Example Street", "guard-token", "guard-project", "guard#{user.id}xxxxx".ljust(22, "x") ].each do |secret|
      assert_not_includes dump, secret, "#{secret.inspect} must not appear in any insights view"
    end
    assert_no_match(/"(user_id|id)"/, dump)
  end

  test "staff, simulated and listed testers appear in no view, whatever they did" do
    ENV["ADMIN_HCA_UIDS"] = "ident!staff"
    ENV["ANALYTICS_EXCLUDE_HCA_UIDS"] = "ident!friend"
    excluded = %w[ident!staff sim!ada ident!friend].map { |uid| User.create!(hca_uid: uid, created_at: Time.utc(2026, 1, 1)) }
    excluded.each { |user| give_every_kind_of_row(user) }
    normal = User.create!(hca_uid: "ident!normal", created_at: Time.utc(2026, 1, 1))
    give_every_kind_of_row(normal)

    ids = excluded.map { |user| analytics_id(user) }
    PUBLIC_VIEWS.each do |view|
      next unless Analytics::Views.columns.any? { |name, column, _| name == view && column == "person_id" }

      assert_empty person_ids(view) & ids, "#{view} shows an excluded person"
    end
    assert_includes person_ids("people"), analytics_id(normal)
    %w[events site_days visits hour_days projects ships orders].each { |view| assert_includes person_ids(view), analytics_id(normal), "#{view} should show the normal person" }
    assert_equal 0, connection.select_value("SELECT COUNT(*) FROM insights.funnel_facts WHERE person_id IN (#{ids.map { |id| connection.quote(id) }.join(', ')})")
  end

  test "the stored flag is enough: flipping it removes a person from every view, flipping it back returns them" do
    user = user_with_rows_in_every_table
    id = analytics_id(user)
    assert_includes person_ids("people"), id
    assert_includes person_ids("events"), id

    user.update_columns(analytics_excluded: true)
    %w[people events visits site_days hour_days projects ships orders nps notifications coin_transactions funnel_facts].each do |view|
      assert_not_includes person_ids(view), id, "#{view} still shows a flagged person"
    end

    user.update_columns(analytics_excluded: false)
    assert_includes person_ids("people"), id
  end

  test "a person added to an exclusion list drops out of every view at the next rebuild, before their next sign-in refreshes the flag" do
    tester = user_with_rows_in_every_table
    id = analytics_id(tester)
    assert_includes person_ids("funnel_facts"), id
    assert_not tester.reload.analytics_excluded?
    before = ParticipantFunnel.run[:total]

    ENV["ANALYTICS_EXCLUDE_HCA_UIDS"] = tester.hca_uid
    assert_not Analytics::Views.current?, "the lists are part of the rendered file, so a changed list makes the views stale"
    assert Analytics::Views.ensure_current!, "db:prepare on the next deploy rebuilds them"
    %w[people events visits site_days hour_days projects ships orders nps notifications coin_transactions funnel_facts].each do |view|
      assert_not_includes person_ids(view), id, "#{view} still shows a listed tester"
    end
    assert_equal before - 1, ParticipantFunnel.run[:total]
  end

  test "a migration that retypes a column the views read needs no care: the views are dropped before it and rebuilt after it" do
    migration = Class.new(ActiveRecord::Migration[8.1]) do
      def up = change_column(:users, :project_kind, :text) # users.project_kind is read by insights.people

      def down = nil
    end.new

    ActiveRecord::Migration.suppress_messages { migration.migrate(:up) }

    assert Analytics::Views.present?
    assert_equal PUBLIC_VIEWS.sort, Analytics::Views.names
    assert_predicate Analytics::Views, :current?
  ensure
    User.reset_column_information
  end

  test "a visit stamped with an excluded person is not shown with their id, and an anonymous one is shown without any" do
    staff = User.create!(hca_uid: "sim!zed", created_at: Time.utc(2026, 1, 1))
    own = AnalyticsVisit.create!(visit_key: "a" * 22, user: staff, started_at: Time.current)
    AnalyticsEvent.create!(name: "landing_viewed", visit: own, user: staff, occurred_at: Time.current)
    anonymous = AnalyticsVisit.create!(visit_key: "b" * 22, started_at: Time.current, referral_slug: "haven")
    AnalyticsEvent.create!(name: "landing_viewed", visit: anonymous, occurred_at: Time.current)

    visit_ids = connection.select_values("SELECT visit_id FROM insights.visits")
    assert_includes visit_ids, anonymous.id
    assert_not_includes visit_ids, own.id
    assert_equal [ nil ], connection.select_values("SELECT person_id FROM insights.visits WHERE visit_id = #{anonymous.id}")
    assert_equal [ anonymous.id ], connection.select_values("SELECT visit_id FROM insights.events WHERE visit_id IN (#{anonymous.id}, #{own.id})")
  end

  test "a person deleted at their own request disappears from every view, and takes their pre-sign-up trail with them" do
    user = user_with_rows_in_every_table
    visit = AnalyticsVisit.find_by!(user: user)
    before = ParticipantFunnel.run[:total]
    id = analytics_id(user)
    assert_includes person_ids("people"), id

    subject = Privacy::TokenVerifier::Subject.new(emails: [], slack_id: nil, identity_id: user.hca_uid)
    result = Privacy::Deleter.new(subject).call(dry_run: false)
    assert result.found

    assert_equal before - 1, ParticipantFunnel.run[:total]
    PUBLIC_VIEWS.each do |view|
      next unless Analytics::Views.columns.any? { |name, column, _| name == view && column == "person_id" }

      assert_not_includes person_ids(view), id, "#{view} still shows a deleted person"
    end
    assert_empty connection.select_values("SELECT visit_id FROM insights.visits WHERE visit_id = #{visit.id}")
    assert_empty connection.select_values("SELECT event_id FROM insights.events WHERE visit_id = #{visit.id}")
  end

  test "review_actions_daily counts staff actions per day without an actor or a subject" do
    user = users(:onboarded)
    project = Project.create!(user: user, name: "Reviewed", kind: "game")
    project.update_columns(review_status: "ok", reviewed_at: Time.current)
    ProjectReview.create!(project: project, status: "ok", created_at: Time.utc(2026, 11, 10, 9))
    ship = Ship.create!(user: user, project: project, status: "rejected", description: "x", repo_url: "https://github.com/a/b", coded_seconds: 600, rejection_reason: "no",
                        window_start_date: Date.new(2026, 11, 9), window_end_date: Date.new(2026, 11, 9), daily_seconds: { "2026-11-09" => 600 }, submitted_at: Time.utc(2026, 11, 9), reviewed_at: Time.utc(2026, 11, 10, 10))
    assert ship.persisted?
    order = Order.create!(user: user, prize_key: "sticker_pack", prize_name: "Stickers", coins: 20, kind: "purchase", idempotency_key: "rad-1")
    OrderEvent.create!(order: order, actor_kind: "staff", action: "held", from_status: "requested", to_status: "on_hold", created_at: Time.utc(2026, 11, 10, 11))
    OrderEvent.create!(order: order, actor_kind: "buyer", action: "cancelled", from_status: "requested", to_status: "cancelled", created_at: Time.utc(2026, 11, 10, 12))

    rows = connection.select_rows("SELECT day, kind, count FROM insights.review_actions_daily WHERE day = DATE '2026-11-10' ORDER BY kind")
    assert_equal [ [ Date.new(2026, 11, 10), "order_held", 1 ], [ Date.new(2026, 11, 10), "project_reviewed", 1 ], [ Date.new(2026, 11, 10), "ship_rejected", 1 ] ], rows
    assert_equal %w[day kind count], connection.columns("insights.review_actions_daily").map(&:name)
  end

  private

  # One row in every table the views read, for someone who is in the analytics.
  def give_every_kind_of_row(user)
    user.update_columns(onboarded_at: Time.utc(2026, 11, 2), onboarding_step: 6)
    project = Project.create!(user: user, name: "P#{user.id}", kind: "game")
    project.hackatime_links.create!(user_id: user.id, hackatime_project: "p#{user.id}", link_method: "manual")
    HourEntry.create!(user: user, local_date: Date.new(2026, 11, 3), seconds: 1200, source: "manual", note: "t", idempotency_key: "v-#{user.id}")
    DailyResult.create!(user: user, local_date: Date.new(2026, 11, 3), raw_seconds: 1200, quick_met: true, goal_met: false, streak_15: 1, goal_streak: 0, freeze_available: true)
    Ship.create!(user: user, project: project, status: "submitted", description: "x", repo_url: "https://github.com/a/b", coded_seconds: 1200,
                 window_start_date: Date.new(2026, 11, 3), window_end_date: Date.new(2026, 11, 3), daily_seconds: { "2026-11-03" => 1200 }, submitted_at: Time.utc(2026, 11, 4))
    Order.create!(user: user, prize_key: "sticker_pack", prize_name: "Stickers", coins: 20, kind: "purchase", idempotency_key: "v-#{user.id}")
    CoinTransaction.create!(user: user, amount: 5, kind: "refund", idempotency_key: "v-#{user.id}")
    Notification.create!(user: user, kind: "daily_reminder", status: "sent", scheduled_for: Time.current, due_at: Time.current, idempotency_key: "v-#{user.id}")
    NpsResponse.create!(user: user, score: 9, answered_at: Time.current, prompt_window_date: Date.new(2026, 11, 3))
    AnalyticsSiteDay.create!(user: user, day: Date.new(2026, 11, 3))
    visit = AnalyticsVisit.create!(visit_key: "v#{user.id}".ljust(22, "x"), user: user, started_at: Time.current)
    AnalyticsEvent.create!(name: "landing_viewed", user: user, visit: visit, occurred_at: Time.current)
  end
end
