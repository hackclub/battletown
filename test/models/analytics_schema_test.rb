require "test_helper"
require_relative "../support/every_table_rows"

# The analytics tables hold no personal data by construction (a reviewed list of columns), cascade from users, and are deleted with the person.
class AnalyticsSchemaTest < ActiveSupport::TestCase
  include EveryTableRows

  # The exact columns. A new column fails this test until someone has reviewed it against the privacy rules (no IP, user agent, URL, name,
  # email, Slack id, free text or address, ever).
  COLUMNS = {
    "analytics_visits" => %w[id visit_key user_id started_at referral_slug utm_source utm_medium utm_campaign referrer_kind device_class entry_route],
    "analytics_events" => %w[id name props occurred_at visit_id user_id dedupe_key],
    "analytics_site_days" => %w[id user_id day],
    "analytics_daily_snapshots" => %w[id day key value],
    "job_runs" => %w[id name started_at finished_at status error_class counts]
  }.freeze
  PERSONAL_NAME = /ip|agent|ua\b|referrer(?!_kind)|referer|landing|url|path|query|email|name$|slack|hca|address|phone|birth|locale|language|geo|city|country|lat|lng|zone|screen|fingerprint|ident|comment|note|idea|text|body/

  def connection = ActiveRecord::Base.connection

  test "the analytics tables have exactly the reviewed columns" do
    COLUMNS.each { |table, columns| assert_equal columns.sort, connection.columns(table).map(&:name).sort, table }
  end

  test "no analytics column is named like personal data" do
    allowed = %w[name referrer_kind entry_route error_class] # event/job names are catalogue keys; the others are enums or controller#action
    COLUMNS.each do |table, columns|
      (columns - allowed).each { |column| assert_no_match(PERSONAL_NAME, column, "#{table}.#{column}") }
    end
  end

  test "string columns are short and the enumerated ones are database checks" do
    connection.columns("analytics_visits").select { |column| column.type == :string }.each { |column| assert_operator column.limit, :<=, 80, column.name }
    checks = connection.check_constraints("analytics_visits").map(&:expression).join(" ")
    assert_match(/referrer_kind/, checks)
    assert_match(/device_class/, checks)
    props_checks = connection.check_constraints("analytics_events").map(&:expression).join(" ")
    assert_match(/jsonb_typeof\(props\)/, props_checks)
    assert_match(/octet_length\(props/, props_checks)
    assert_raises(ActiveRecord::StatementInvalid) do
      AnalyticsEvent.insert_all!([ { name: "landing_viewed", props: { "x" => "y" * 500 }, occurred_at: Time.current, user_id: users(:onboarded).id } ])
    end
  end

  test "every analytics row about a person cascades from users, and the events also cascade from their visit" do
    cascades = ->(table, column, to) { connection.foreign_keys(table).any? { |fk| fk.column == column && fk.to_table == to && fk.on_delete == :cascade } }
    assert cascades.call("analytics_visits", "user_id", "users")
    assert cascades.call("analytics_events", "user_id", "users")
    assert cascades.call("analytics_events", "visit_id", "analytics_visits")
    assert cascades.call("analytics_site_days", "user_id", "users")
  end

  test "the stored indexes are the ones queries need: no single-column index that another one already covers" do
    events = connection.indexes("analytics_events").reject { |index| index.name == "index_analytics_events_hackatime_linked" }.map { |index| index.columns }
    assert_includes events, %w[name occurred_at]
    assert_includes events, %w[user_id occurred_at]
    assert_includes events, %w[visit_id]
    assert_not_includes events, %w[user_id]
    assert_equal 5, events.size, "the dedupe key, (name, time), (user, time), (visit) and the BRIN on time"
    # Nothing is pruned, so a range over every event (the hourly snapshot, the admin page) must not scan the whole table: a BRIN on the time alone is
    # almost free for an append-only table.
    assert_equal [ "brin" ], connection.indexes("analytics_events").select { |index| index.columns == %w[occurred_at] }.map { |index| index.using.to_s }
    # The insights views look up each person's first Hackatime link: a partial index that holds one row per linked person (migration CreateInsightsViews).
    assert_equal [ "((name)::text = 'hackatime_linked'::text)" ], connection.indexes("analytics_events").filter_map(&:where).grep(/hackatime_linked/)
  end

  test "deleting a person through Privacy::Deleter removes their visits (and the events of them), events and days of presence, and a dry run counts them" do
    user = user_with_rows_in_every_table
    stranger = AnalyticsVisit.create!(visit_key: "s" * 22, started_at: Time.current) # an anonymous visitor who never signed up
    AnalyticsEvent.create!(name: "landing_viewed", visit: stranger, occurred_at: Time.current)
    pre_signup = AnalyticsVisit.create!(visit_key: "p" * 22, started_at: Time.current, user: user) # stamped at sign-in
    AnalyticsEvent.create!(name: "onboarding_step_viewed", props: { "step" => "age" }, visit: pre_signup, user: user, occurred_at: Time.current)
    subject = Privacy::TokenVerifier::Subject.new(emails: [], slack_id: nil, identity_id: user.hca_uid)

    own_events = AnalyticsEvent.where(user_id: user.id).count # the two above, and whatever the services that built their rows recorded
    assert_operator own_events, :>=, 2

    dry = Privacy::Deleter.new(subject).call(dry_run: true)
    assert_equal({ "analytics_visits" => 2, "analytics_events" => own_events, "analytics_site_days" => 1 }, dry.deleted.slice("analytics_visits", "analytics_events", "analytics_site_days"))
    assert_equal 2, AnalyticsVisit.where(user_id: user.id).count, "a dry run deletes nothing"

    Privacy::Deleter.new(subject).call(dry_run: false)
    assert_equal 0, AnalyticsVisit.where(user_id: user.id).count + AnalyticsEvent.where(user_id: user.id).count + AnalyticsSiteDay.where(user_id: user.id).count
    assert_equal [ stranger.id ], AnalyticsVisit.pluck(:id), "someone else's (anonymous) visit is untouched"
    assert_equal 1, AnalyticsEvent.count
  end
end
