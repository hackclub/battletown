require "test_helper"
require_relative "../support/ships_test_support"
require_relative "../support/shop_helper"
require_relative "../support/hackatime_helper"

class AdminMetricsTest < ActiveSupport::TestCase
  include ShipsTestSupport
  include ShopTestHelper
  include HackatimeHelper

  TODAY = Date.new(2026, 11, 12) # a Thursday: the last day of the boss week that started Friday 6 November
  MINUTE = 60

  setup do
    @teen = users(:new_user)
    @vet = users(:onboarded)
  end

  def metrics = AdminMetrics.call(today: TODAY)

  def add(user, date, seconds, source: "manual")
    HourEntry.create!(user: user, local_date: date, seconds: seconds, source: source, note: (source == "hackatime" ? nil : "test"),
                      idempotency_key: SecureRandom.hex(8))
  end

  # Signed up long before any date here, like the fixtures, so the sign-up cutoff leaves their hours alone.
  def extra_user(n) = User.create!(hca_uid: "metrics-#{n}", created_at: Time.utc(2026, 1, 1))

  def daily_on(date) = metrics.daily.find { |day| day.date == date }

  def funnel = metrics.funnel.to_h { |step| [ step.label, step.count ] }

  def dropout = metrics.dropout.to_h { |bucket| [ bucket.label, bucket.count ] }

  test "the active threshold is the 15-minute streak threshold from config/game.yml" do
    assert_equal Game::Config.current.quick_seconds, metrics.minimum_seconds
    assert_equal 15 * MINUTE, metrics.minimum_seconds
  end

  test "daily covers the last 28 local dates, oldest first, zero-filled" do
    days = metrics.daily
    assert_equal 28, days.size
    assert_equal TODAY - 27, days.first.date
    assert_equal TODAY, days.last.date
    assert days.all? { |day| day.active_users.zero? && day.seconds.zero? }
  end

  test "a user is active on a day from exactly 15 minutes, summed across that day's rows" do
    add(@teen, TODAY - 1, 15 * MINUTE)
    add(@vet, TODAY - 1, 14 * MINUTE)
    add(@vet, TODAY - 2, 10 * MINUTE)
    add(@vet, TODAY - 2, 5 * MINUTE)

    assert_equal 1, daily_on(TODAY - 1).active_users
    assert_equal 29 * MINUTE, daily_on(TODAY - 1).seconds
    assert_equal 1, daily_on(TODAY - 2).active_users
    assert_equal 15 * MINUTE, daily_on(TODAY - 2).seconds
  end

  test "a correction that takes a day below the threshold makes it inactive, and a negative day adds nothing" do
    add(@teen, TODAY - 3, 20 * MINUTE)
    add(@teen, TODAY - 3, -10 * MINUTE, source: "adjustment")
    add(@vet, TODAY - 3, 30 * MINUTE)
    add(@vet, TODAY - 3, -30 * MINUTE, source: "adjustment")
    add(@vet, TODAY - 3, -5 * MINUTE, source: "adjustment")

    assert_equal 0, daily_on(TODAY - 3).active_users
    assert_equal 10 * MINUTE, daily_on(TODAY - 3).seconds
  end

  test "days outside the window are not counted" do
    add(@teen, TODAY - 28, HOUR)
    add(@teen, TODAY + 1, HOUR)
    assert_equal 0, metrics.daily.sum(&:seconds)
  end

  test "weekly runs Friday to Thursday, like the boss, with the current week last" do
    weeks = metrics.weekly
    assert_equal 8, weeks.size
    assert weeks.all? { |week| week.starts_on.friday? && week.ends_on == week.starts_on + 6 }
    assert_equal Date.new(2026, 11, 6), weeks.last.starts_on
    assert_equal TODAY, weeks.last.ends_on
    assert_not weeks.last.partial, "the week ends today, so it is not marked as past today"

    partial = AdminMetrics.call(today: Date.new(2026, 11, 13)).weekly.last
    assert_equal Date.new(2026, 11, 13), partial.starts_on
    assert partial.partial
  end

  test "weekly counts each person once however many days they were active" do
    add(@teen, Date.new(2026, 11, 6), HOUR)  # Friday, this week
    add(@teen, Date.new(2026, 11, 10), HOUR) # Tuesday, this week
    add(@vet, Date.new(2026, 11, 12), 16 * MINUTE)
    add(@vet, Date.new(2026, 11, 5), HOUR) # Thursday, last week
    add(extra_user(1), Date.new(2026, 11, 11), 5 * MINUTE) # below the threshold

    weeks = metrics.weekly.to_h { |week| [ week.starts_on, week.active_users ] }
    assert_equal 2, weeks[Date.new(2026, 11, 6)]
    assert_equal 1, weeks[Date.new(2026, 10, 30)]
    assert_equal 3, weeks.values.sum
  end

  test "the funnel counts each step all-time as a share of everyone who signed up" do
    # Fixtures: the vet is onboarded, the teen is not.
    connect_hackatime(@teen)
    third = extra_user(1)
    add(third, TODAY - 40, 5 * MINUTE, source: "hackatime") # Hackatime time, never an active day
    add(@vet, TODAY - 40, HOUR)
    project = make_project(@vet)
    code(@vet, Date.new(2026, 11, 8), 2 * HOUR)
    ship = submit_ship(project)
    Ships::Approve.call(ship: ship, reviewer: @teen, approved_seconds: HOUR, now: Time.current)
    second_project = make_project(@teen, name: "Other", hackatime: "other")
    code(@teen, Date.new(2026, 11, 9), 2 * HOUR, hackatime: "other")
    submit_ship(second_project)
    verified!(@vet)
    give_coins(@vet, 1000)
    buy(@vet, "keychain")
    Shop::ClaimSticker.call(user: @teen)
    verified!(third)
    give_coins(third, 1000)
    Shop::Cancel.call(order: buy(third, "keychain"), by: third)

    assert_equal(
      { "Signed up" => 3, "Onboarded" => 1, "Connected Hackatime" => 2, "First coded day" => 2, "First ship submitted" => 2,
        "First ship approved" => 1, "First purchase" => 1 }, funnel
    )
    assert_equal [ 100.0, 33.3, 66.7, 66.7, 66.7, 33.3, 33.3 ], metrics.funnel.map(&:percent)
  end

  test "a first coded day needs the threshold within one local date, however many rows make it up" do
    split = extra_user(2)
    add(split, TODAY - 3, 10 * MINUTE)
    add(split, TODAY - 3, 5 * MINUTE)
    spread = extra_user(3)
    add(spread, TODAY - 3, 10 * MINUTE)
    add(spread, TODAY - 2, 10 * MINUTE)

    assert_equal 1, funnel["First coded day"]
  end

  test "the funnel is all zero percent with no users" do
    User.delete_all
    assert metrics.funnel.all? { |step| step.count.zero? && step.percent.zero? }
  end

  test "dropout buckets everyone who was ever active by their last active day" do
    add(@teen, TODAY, HOUR)
    add(@teen, TODAY - 5, HOUR)
    add(@vet, TODAY - 1, HOUR)
    add(@vet, TODAY, 5 * MINUTE) # today is below the threshold, so the last active day is yesterday
    add(extra_user(1), TODAY - 14, HOUR)
    add(extra_user(2), TODAY - 15, HOUR)
    add(extra_user(3), TODAY - 200, HOUR)
    add(extra_user(4), TODAY - 3, 10 * MINUTE) # never active
    add(extra_user(5), TODAY + 1, HOUR) # a local date ahead of UTC today is ignored

    buckets = metrics.dropout
    assert_equal 16, buckets.size
    assert_equal [ "Today", "1 day ago", "2 days ago" ], buckets.first(3).map(&:label)
    assert_equal "More than 14 days ago", buckets.last.label
    assert_equal 1, dropout["Today"]
    assert_equal 1, dropout["1 day ago"]
    assert_equal 1, dropout["14 days ago"]
    assert_equal 2, dropout["More than 14 days ago"]
    assert_equal 5, buckets.sum(&:count)
  end

  test "hours dated before a person signed up count for nothing, as in the game" do
    @teen.update_columns(signed_up_on: TODAY - 5)
    add(@teen, TODAY - 6, HOUR) # Hackatime back-fill from the day before sign-up

    assert_equal 0, daily_on(TODAY - 6).active_users
    assert_equal 0, daily_on(TODAY - 6).seconds
    assert_equal 0, metrics.weekly.sum(&:active_users)
    assert_equal 0, funnel["First coded day"]
    assert_equal 0, metrics.dropout.sum(&:count)

    add(@teen, TODAY - 5, HOUR) # the sign-up date itself counts fully
    assert_equal [ 1, HOUR ], [ daily_on(TODAY - 5).active_users, daily_on(TODAY - 5).seconds ]
    assert_equal 1, metrics.weekly.sum(&:active_users)
    assert_equal 1, funnel["First coded day"]
    assert_equal 1, dropout["5 days ago"]
  end

  test "days_before_signup_counted lets earlier days count here too" do
    @teen.update_columns(signed_up_on: TODAY - 5)
    add(@teen, TODAY - 6, HOUR)
    add(@teen, TODAY - 7, HOUR)

    original = Hours::Config.current
    Hours::Config.instance_variable_set(:@current, original.with(days_before_signup_counted: 1))
    assert_equal [ 1, HOUR ], [ daily_on(TODAY - 6).active_users, daily_on(TODAY - 6).seconds ]
    assert_equal 0, daily_on(TODAY - 7).seconds
    assert_equal 1, funnel["First coded day"]
    assert_equal 1, dropout["6 days ago"]
  ensure
    Hours::Config.instance_variable_set(:@current, original)
  end

  test "each breakdown is one query, whatever the number of users" do
    count = lambda do
      queries = 0
      callback = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { metrics }
      queries
    end
    add(@teen, TODAY, HOUR)
    assert_equal 4, count.call
    10.times { |n| add(extra_user(n), TODAY - (n % 3), HOUR) }
    assert_equal 4, count.call
  end

  test "the result holds only dates, labels, counts and sums" do
    add(@teen, TODAY, HOUR)
    flat = metrics.to_h.values.flatten.flat_map { |value| value.respond_to?(:to_h) ? value.to_h.values : [ value ] }
    assert flat.all? { |value| value.is_a?(Numeric) || value.is_a?(Date) || value.is_a?(String) || value == true || value == false }
    assert_not flat.include?(@teen.id)
  end
end
