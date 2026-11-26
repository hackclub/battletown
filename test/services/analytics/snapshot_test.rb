require "test_helper"
require "rake"
require_relative "../../support/coins_helper"
require_relative "../../support/bosses_helper"

# Analytics::Snapshot: stored daily aggregates, with no person in them, that outlive the people and the rows they were counted from.
class AnalyticsSnapshotTest < ActiveSupport::TestCase
  include CoinsHelper
  include BossesHelper

  DAY = Date.new(2026, 11, 16) # a Monday inside the FRIDAY (2026-11-13) boss week
  NOON = Time.utc(2026, 11, 16, 12)

  setup { travel_to(NOON) }

  def snapshot(day = DAY) = Analytics::Snapshot.call(day: day)

  def value(key, day = DAY) = AnalyticsDailySnapshot.find_by(day: day, key: key)&.value

  def order_for(user, status: "requested")
    Order.create!(user: user, prize_key: "tshirt", prize_name: "T-shirt", coins: 100, kind: "purchase", status: status,
                  idempotency_key: SecureRandom.hex(8), cancelled_at: (Time.current if status == "cancelled"))
  end

  test "it stores one row per key for the day, with a number and no person" do
    result = snapshot

    assert_equal DAY, result.day
    assert_equal result.keys, AnalyticsDailySnapshot.where(day: DAY).count
    assert_equal %w[id day key value], AnalyticsDailySnapshot.column_names
    AnalyticsDailySnapshot.where(day: DAY).each do |row|
      assert_match AnalyticsDailySnapshot::KEY_FORMAT, row.key
      assert_kind_of Integer, row.value
    end
    %w[funnel.signed_up.ever funnel.purchased.ever people.total people.active people.site_day signups hours.coded_seconds ships.submitted
       ships.pending_review ships.oldest_wait_hours orders.requested visits.total visits.signed_up events.total].each do |key|
      assert_not_nil value(key), key
    end
  end

  test "running it again overwrites today's numbers and writes no second row" do
    snapshot
    rows = AnalyticsDailySnapshot.count
    total = value("people.total")
    build_user

    snapshot
    assert_equal rows, AnalyticsDailySnapshot.count
    assert_equal total + 1, value("people.total")
  end

  test "another day's rows are never touched" do
    snapshot(DAY - 1)
    before = AnalyticsDailySnapshot.where(day: DAY - 1).order(:key).pluck(:key, :value)
    build_user

    snapshot
    assert_equal before, AnalyticsDailySnapshot.where(day: DAY - 1).order(:key).pluck(:key, :value)
  end

  test "small cells are stored exactly: a stored history can never be turned back from a suppressed value" do
    3.times { order_for(build_user) }
    snapshot
    assert_equal 3, value("orders.requested")
    assert_equal 0, value("orders.shipped")

    buyer = build_user
    2.times { order_for(buyer) }
    snapshot
    assert_equal 5, value("orders.requested")
    assert_empty AnalyticsDailySnapshot.where("value < 0"), "no key holds a placeholder"
  end

  test "staff, simulated and listed players are left out of every number" do
    before = snapshot.then { { people: value("people.total"), pending: value("ships.pending_review") } }
    sim = User.create!(hca_uid: "sim!#{SecureRandom.hex(4)}", display_name: "Sim", created_at: NOON, signed_up_on: DAY)
    ship_damage(sim, 3600, on: DAY)
    5.times { order_for(sim) }

    snapshot
    assert_equal before[:people], value("people.total")
    assert_equal before[:pending], value("ships.pending_review")
    assert_equal 0, value("orders.requested")
  end

  test "ships by status, the review queue and the boss come from real people" do
    make_boss
    people = Array.new(5) { build_user }
    people.each { |person| ship_damage(person, 3600, on: DAY - 1) }
    ship_damage(people.first, 7200, on: DAY - 1, status: "approved", approved_seconds: 3600)
    ship_damage(people.second, 1800, on: DAY - 1, status: "rejected")

    snapshot
    assert_equal 5, value("ships.submitted")
    assert_equal 1, value("ships.approved")
    assert_equal 5, value("ships.pending_review")
    assert_operator value("ships.oldest_wait_hours"), :>=, 24
    assert_equal 5 * 3600 + 3600, value("boss.damage_seconds")
  end

  test "no boss key without a boss for the day" do
    snapshot

    assert_nil value("boss.damage_seconds")
  end

  test "coins, notifications and hackatime breakdowns are keyed by kind, channel and state" do
    people = Array.new(5) { build_user }
    people.each do |person|
      CoinTransaction.create!(user: person, amount: 40, kind: "ship_approval", idempotency_key: SecureRandom.hex(8), created_at: NOON)
      CoinTransaction.create!(user: person, amount: -15, kind: "purchase", idempotency_key: SecureRandom.hex(8), created_at: NOON)
      Notification.create!(user: person, kind: "daily_reminder", channel: "email", status: "sent", scheduled_for: NOON, due_at: NOON,
                           idempotency_key: SecureRandom.hex(8))
      HackatimeConnection.create!(user: person, hackatime_uid: SecureRandom.random_number(10**9).to_s, access_token: "t", connected_at: NOON, last_synced_at: NOON)
    end

    snapshot
    assert_equal 200, value("coins.issued.ship_approval")
    assert_equal 75, value("coins.spent.purchase")
    assert_equal 5, value("notifications.email.daily_reminder.sent")
    assert_equal 5, value("hackatime.healthy")
    assert_equal 0, value("hackatime.needs_reconnect")
  end

  test "events and visits are counted for the day" do
    visitors = Array.new(5) { |index| AnalyticsVisit.create!(visit_key: SecureRandom.hex(16), started_at: NOON - index.minutes) }
    visitors.each { |visit| AnalyticsEvent.create!(name: "landing_viewed", props: {}, occurred_at: NOON, visit: visit) }
    AnalyticsVisit.create!(visit_key: SecureRandom.hex(16), started_at: NOON - 2.days)

    snapshot
    assert_equal 5, value("visits.total")
    assert_equal 5, value("events.landing_viewed")
    assert_operator value("events.total"), :>=, 5
    assert_equal 0, value("visits.signed_up")
  end

  test "a visit whose person was created after it began counts as signed up" do
    visit = AnalyticsVisit.create!(visit_key: SecureRandom.hex(16), started_at: NOON - 10.minutes)
    visit.update!(user: build_user.tap { |person| person.update_columns(created_at: NOON - 5.minutes) })

    snapshot
    assert_equal 1, value("visits.signed_up")
  end

  test "deleting a person afterwards leaves what was stored" do
    people = Array.new(5) { build_user }
    people.each { |person| order_for(person) }
    snapshot
    assert_equal 5, value("orders.requested")

    people.each(&:destroy!)
    assert_equal 5, value("orders.requested")
    assert_equal 5, AnalyticsDailySnapshot.find_by!(day: DAY, key: "orders.requested").value
  end

  test "nothing stored names or points at a person" do
    person = build_user
    person.update_columns(display_name: "Quentin Q. Uniqueperson", email: "quentin.unique@example.com", slack_id: "UQUENTIN99")
    order_for(person)
    snapshot

    stored = AnalyticsDailySnapshot.pluck(:key, :value).flatten.join(" ")
    [ "Quentin", "quentin", "UQUENTIN99", person.hca_uid, person.id.to_s ].each { |text| assert_not_includes stored, text unless text == person.id.to_s }
    assert_not_includes AnalyticsDailySnapshot.column_names, "user_id"
  end

  test "finishing yesterday rewrites its flows for the whole day, keeps its gauges and does it once" do
    people = Array.new(2) { build_user }
    travel_to(Time.utc(2026, 11, 16, 23, 45))
    snapshot
    people.each { |person| person.update_columns(created_at: Time.utc(2026, 11, 16, 23, 50)) }
    order_for(people.first)
    gauge = value("people.total")
    assert_equal 0, value("signups")

    travel_to(Time.utc(2026, 11, 17, 0, 45))
    finished = Analytics::Snapshot.finalize_previous_day

    assert_equal DAY, finished.day
    assert_equal 2, value("signups"), "the people who joined in the last 15 minutes are in"
    assert_equal gauge, value("people.total"), "a gauge keeps the value of the last run of the day"
    assert_equal 0, value("orders.requested"), "so does an order gauge"
    assert_equal 1, value(Analytics::Snapshot::FINAL_KEY)
    assert_nil Analytics::Snapshot.finalize_previous_day, "once"
  end

  test "there is nothing to finish for a day the job never ran" do
    assert_nil Analytics::Snapshot.finalize_previous_day(today: DAY)
    assert_equal 0, AnalyticsDailySnapshot.count
  end

  test "rake analytics:snapshot writes the day, prints counts only and records its run" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("analytics:snapshot")
    task = Rake::Task["analytics:snapshot"]
    task.reenable
    output = capture_io { task.invoke }.first

    assert_match(/\Aanalytics:snapshot day=2026-11-16 keys=\d+\n\z/, output)
    run = JobRun.find_by!(name: "analytics:snapshot")
    assert_equal "ok", run.status
    assert_equal AnalyticsDailySnapshot.where(day: DAY).count, run.counts["keys"]
  end
end
