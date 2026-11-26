require "test_helper"
require_relative "../../support/coins_helper"
require_relative "../../support/ships_test_support"
require_relative "../../support/bosses_helper"
require_relative "../../support/orders_helper"
require_relative "../../support/notifications_helper"
require_relative "../../support/quests_helper"

# The product events (plans/analytics.md): each fires exactly once on the real service path, is idempotent on retries, is never recorded for
# staff or simulated players, and a failure inside analytics never breaks the action it measures. Nothing here reads a name, text or id of a person.
class AnalyticsProductEventsTest < ActiveSupport::TestCase
  include CoinsHelper
  include ShipsTestSupport
  include BossesHelper
  include OrdersTestHelper
  include NotificationsHelper
  include QuestsHelper

  NOW = Time.utc(2026, 11, 16, 12)
  D = ->(day) { Date.new(2026, 11, day) }

  setup do
    travel_to NOW
    @user = build_user(created_on: D[1])
    @reviewer = users(:onboarded)
  end

  teardown { travel_back }

  def production_mode(&block) = stub_method(Analytics, :strict?, -> { false }, &block)

  def events(name) = AnalyticsEvent.where(name: name.to_s).order(:id)

  def only(name) = events(name).sole

  def capture_log
    io = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    yield
    io.string
  ensure
    Rails.logger = original
  end

  # A project with a linked Hackatime project (a new name each time) and `hours` one-hour days of coding on it.
  def shippable_project(user = @user, hours: 3, from: 10)
    name = "farm-#{SecureRandom.hex(3)}"
    project = make_project(user, name: name.titleize, hackatime: name)
    (from...(from + hours)).each { |day| code(user, D[day], HOUR, hackatime: name) }
    project
  end

  def approve(ship, now: NOW + 1.day)
    Ships::Approve.call(ship: ship, reviewer: @reviewer, approved_seconds: ship.coded_seconds, now: now)
  end

  # ---- ships and the boss ----

  test "submitting a ship records ship_submitted once, with a bucket, its place and whether it follows a rejection" do
    ship = submit_ship(shippable_project)

    event = only(:ship_submitted)
    assert_equal({ "hours_bucket" => "2-5", "nth" => "1", "after_rejection" => false }, event.props)
    assert_equal @user.id, event.user_id
    assert_not_nil event.occurred_at

    ActiveSupport::Notifications.instrument("ship_submitted.battletown", ship_id: ship.id) # a duplicate announcement
    assert_equal 1, events(:ship_submitted).count
  end

  test "a second ship is the second, and shipping again after a rejection says so" do
    project = shippable_project
    first = submit_ship(project)
    Ships::Reject.call(ship: first, reviewer: @reviewer, reason: "Needs a demo")
    second = submit_ship(project)

    assert_equal second.id, Ship.where(user_id: @user.id, status: "submitted").sole.id
    props = events(:ship_submitted).last.props
    assert_equal [ "2", true ], [ props["nth"], props["after_rejection"] ]
    assert_equal [ "1", false ], events(:ship_submitted).first.props.values_at("nth", "after_rejection")
  end

  test "a submitted ship is one hit on the boss of its week" do
    boss = make_boss(hp_seconds: 500 * HOUR)
    submit_ship(shippable_project(from: 12))

    assert_equal({ "boss_id" => boss.id, "hours_bucket" => "2-5" }, only(:boss_hit).props)
    assert_not_tracked :boss_defeated
  end

  test "no boss that week means no hit" do
    submit_ship(shippable_project)
    assert_not_tracked :boss_hit
  end

  test "the ship that brings the boss down records boss_defeated once, for its owner" do
    boss = make_boss(hp_seconds: 2 * HOUR)
    other = build_user(created_on: D[1])
    submit_ship(shippable_project(other, hours: 1, from: 12)) # not enough on its own
    assert_not_tracked :boss_defeated

    ship = submit_ship(shippable_project(from: 12))
    assert boss.reload.defeated?
    event = only(:boss_defeated)
    assert_equal [ @user.id, { "boss_id" => boss.id } ], [ event.user_id, event.props ]

    Bosses::CheckDefeat.for_ship(ship) # defeat is final: nothing more
    assert_equal 1, events(:boss_defeated).count
  end

  test "approving records ship_approved once with the approved hours bucket and how long it waited" do
    ship = submit_ship(shippable_project)
    approve(ship)

    assert_equal({ "hours_bucket" => "2-5", "nth" => "1", "waited" => "1d" }, only(:ship_approved).props)
    ActiveSupport::Notifications.instrument("ship_approved.battletown", ship_id: ship.id)
    assert_equal 1, events(:ship_approved).count
    assert Ships::Approve.call(ship: ship, reviewer: @reviewer, approved_seconds: ship.coded_seconds).unavailable?, "a second approval does nothing"
    assert_equal 1, events(:ship_approved).count
  end

  test "approved hours are bucketed from what was approved, not what was coded" do
    ship = submit_ship(shippable_project(hours: 6))
    Ships::Approve.call(ship: ship, reviewer: @reviewer, approved_seconds: 90 * 60, now: NOW)

    assert_equal %w[1-2 same_day], only(:ship_approved).props.values_at("hours_bucket", "waited")
  end

  test "rejecting records ship_rejected with no reason" do
    ship = submit_ship(shippable_project)
    Ships::Reject.call(ship: ship, reviewer: @reviewer, reason: "PROBE-REASON text that must never be stored", now: NOW + 3.days)

    event = only(:ship_rejected)
    assert_equal({ "nth" => "1", "waited" => "3plus_d" }, event.props)
    assert_no_match(/PROBE/, event.to_json)
  end

  test "withdrawing a submitted ship records ship_withdrawn, throwing a draft away does not" do
    ship = submit_ship(shippable_project)
    assert Ships::Withdraw.call(ship: ship)
    assert_equal({ "nth" => "1" }, only(:ship_withdrawn).props)
    assert_not Ships::Withdraw.call(ship: ship), "already withdrawn"
    assert_equal 1, events(:ship_withdrawn).count

    draft = submit_ship(shippable_project(from: 20), submit: false)
    assert Ships::Withdraw.call(ship: draft)
    assert_equal 1, events(:ship_withdrawn).count
  end

  test "a draft or a refused submission records nothing" do
    submit_ship(shippable_project, submit: false)
    assert_raises(Ships::Submit::NoHours) { submit_ship(make_project(@user, name: "Empty", hackatime: "empty")) }
    assert_not_tracked :ship_submitted
    assert_not_tracked :boss_hit
  end

  # ---- the armoury ----

  test "buying records order_placed once, a replay of the same order records nothing more" do
    verified!(@user)
    give_coins(@user, 500)
    Shop::Purchase.call(user: @user, prize_key: "tshirt", idempotency_key: "k1")
    Shop::Purchase.call(user: @user, prize_key: "tshirt", idempotency_key: "k1")

    assert_equal({ "item_key" => "tshirt", "coins" => 50, "kind" => "purchase" }, only(:order_placed).props)
    assert_equal @user.id, only(:order_placed).user_id
    Shop::Purchase.call(user: @user, prize_key: "tshirt", idempotency_key: "k2")
    assert_equal 2, events(:order_placed).count
  end

  test "claiming the free sticker records order_placed as a signup sticker" do
    Shop::ClaimSticker.call(user: @user)

    props = only(:order_placed).props
    assert_equal [ 0, "signup_sticker" ], props.values_at("coins", "kind")
    assert_raises(Shop::AlreadyClaimed) { Shop::ClaimSticker.call(user: @user) }
    assert_equal 1, events(:order_placed).count
  end

  test "an order that is rolled back records nothing" do
    verified!(@user)
    give_coins(@user, 500)
    key = "rollback-key"
    assert_raises(Orders::AddressError) do
      Orders::Place.call(user: @user, prize_key: "tshirt", idempotency_key: key, address_id: "nope", address_required: true)
    end

    assert_equal 0, Order.where(user_id: @user.id).count
    assert_not_tracked :order_placed
    assert_equal "address_missing", only(:purchase_refused).props["reason"]
  end

  test "a refused purchase records purchase_refused with a fixed reason and a catalogue item only" do
    verified!(@user)
    assert_raises(Shop::InsufficientCoins) { Orders::Place.call(user: @user, prize_key: "tshirt", idempotency_key: "broke") }
    assert_raises(Shop::UnknownPrize) { Orders::Place.call(user: @user, prize_key: "PROBE item <script>", idempotency_key: "junk") }

    first, second = events(:purchase_refused).to_a
    assert_equal({ "reason" => "insufficient_coins", "item_key" => "tshirt" }, first.props)
    assert_equal({ "reason" => "other" }, second.props)
    assert_no_match(/PROBE/, second.to_json)
    assert_not_tracked :order_placed
  end

  test "order changes record one event each with who acted, as a kind, and never for the staff member" do
    setup_orders_world
    shipped = order_in("shipped")
    fulfilled = order_in("fulfilled")
    order_in("cancelled")
    order_in("refunded")
    Orders::Cancel.call(order: order_for(@buyer), by: @buyer, as: :buyer)
    ActiveSupport::Notifications.instrument("order_shipped.battletown", order_id: shipped.id, actor_kind: "staff") # a duplicate announcement

    assert_equal [ "staff" ] * 2, events(:order_shipped).map { |event| event.props["actor_kind"] } # the shipped one and the refunded one
    assert_equal [ "staff" ], events(:order_fulfilled).map { |event| event.props["actor_kind"] }
    assert_equal %w[staff buyer], events(:order_cancelled).map { |event| event.props["actor_kind"] }
    assert_equal [ "staff" ], events(:order_refunded).map { |event| event.props["actor_kind"] }
    assert_equal [ @buyer.id ], AnalyticsEvent.where(name: %w[order_shipped order_fulfilled order_cancelled order_refunded]).distinct.pluck(:user_id)
    assert_equal 1, events(:order_fulfilled).where(user_id: fulfilled.user_id).count
  ensure
    teardown_orders_world
  end

  # ---- hours, days and streaks ----

  def sync(*rows) = Hours::Sync.call(rows, user: @user)

  def day_row(seconds, date: D[16]) = Hackatime::DaySeconds.new(date: date, seconds: seconds, project: "space-farm")

  test "the first Hackatime hours, the 15-minute day and the pace goal each record once however often the sync runs" do
    @user.update!(pace_minutes: 30)
    sync(day_row(10 * 60))
    assert_equal 1, events(:first_hours_credited).count
    assert_equal 0, events(:quick_day_reached).count

    sync(day_row(20 * 60))
    sync(day_row(20 * 60))
    sync(day_row(40 * 60))
    sync(day_row(40 * 60))
    sync(day_row(5 * 3600))

    assert_equal 1, events(:first_hours_credited).count
    assert_equal 1, events(:quick_day_reached).count
    goal = only(:daily_goal_reached)
    assert_equal({ "pace_minutes" => 30 }, goal.props)
    assert_equal [ @user.id ], events(:quick_day_reached).pluck(:user_id)
  end

  test "after the first Hackatime hours a credit does not even try to insert the event again" do
    sync(day_row(10 * 60, date: D[15]))
    inserts = []
    callback = ->(*, payload) { inserts << payload[:sql] if payload[:sql].match?(/INSERT INTO "analytics_events".*first_hours_credited/m) }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { sync(day_row(10 * 60, date: D[16])) }

    assert_empty inserts
    assert_equal 1, events(:first_hours_credited).count
  end

  test "a second day is its own quick day, and the first hours only count once" do
    sync(day_row(20 * 60, date: D[15]))
    sync(day_row(20 * 60, date: D[16]))

    assert_equal 1, events(:first_hours_credited).count
    assert_equal 2, events(:quick_day_reached).count
  end

  test "a manual credit is not a first Hackatime hour, and a day before the game counts hours records no day events" do
    Hours::Credit.call(user: @user, seconds: 3600, source: "manual", idempotency_key: "m1", local_date: D[16], note: "workshop")
    assert_not_tracked :first_hours_credited
    assert_equal 1, events(:quick_day_reached).count

    early = build_user(created_on: D[15])
    Hours::Credit.call(user: early, seconds: 3600, source: "hackatime", idempotency_key: "h1", local_date: D[14])
    assert_equal 1, events(:first_hours_credited).where(user_id: early.id).count
    assert_equal 0, events(:quick_day_reached).where(user_id: early.id).count
  end

  test "an adjustment that takes time away records no new day event" do
    sync(day_row(20 * 60))
    Hours::Credit.call(user: @user, seconds: -600, source: "adjustment", idempotency_key: "a1", local_date: D[16], note: "fix")
    assert_equal 1, events(:quick_day_reached).count
    assert_equal 1, events(:first_hours_credited).count
  end

  test "settling records the streak growing, the freeze saving it and the streak ending, once each however often it runs" do
    source = StubHoursSource.new({ D[1] => 900, D[2] => 900, D[3] => 900, D[4] => 0, D[5] => 0, D[6] => 900 })
    Game::Settle.call(@user, through: Time.utc(2026, 11, 7, 12), source: source)
    Game::Settle.call(@user, through: Time.utc(2026, 11, 7, 12), source: source)

    assert_equal %w[1 2-3 2-3 1], events(:streak_extended).map { |event| event.props["days_bucket"] }
    assert_equal [ { "days_bucket" => "2-3" } ], events(:freeze_used).map(&:props)
    assert_equal [ { "days_bucket" => "2-3" } ], events(:streak_broken).map(&:props)
  end

  test "a day with no streak and no hours records nothing" do
    Game::Settle.call(@user, through: Time.utc(2026, 11, 8, 12), source: StubHoursSource.new)
    assert_equal 0, AnalyticsEvent.where(name: %w[streak_extended streak_broken freeze_used]).count
  end

  test "choosing a pace records pace_set: the onboarding choice while signing up, a later change after it" do
    user = User.create!(hca_uid: "ident!pace-#{SecureRandom.hex(4)}")
    user.update!(pace_minutes: 30)
    user.update!(onboarded_at: Time.current)
    user.update!(pace_minutes: 60)
    user.update!(coding_time: "18:30") # not a pace change

    assert_equal [ { "pace_minutes" => 30, "source" => "onboarding" }, { "pace_minutes" => 60, "source" => "later" } ], events(:pace_set).map(&:props)
  end

  # ---- messages, feedback, quests, crews, plinko ----

  def dispatch(adapter, row, now: row.scheduled_for + 1.minute)
    with_env("NOTIFICATIONS_ENABLED" => "true") { Notifications::Dispatcher.run(now: now, adapter: adapter) }
  end

  test "a delivered message records notification_sent once, with the kind and channel and nothing of the text" do
    user = create_user
    row = Notifications::Scheduler.schedule_next(user, now: NOW - 1.day)
    dispatch(NotificationsHelper::FakeAdapter.new, row)

    props = only(:notification_sent).props
    assert_equal({ "kind" => "daily_reminder", "channel" => "slack_dm" }, props)
    assert_equal user.id, only(:notification_sent).user_id
    assert_not_tracked :notification_failed
  end

  test "a message that failed for good records notification_failed with its code; retries and skipped rows record nothing" do
    user = create_user
    row = Notifications::Scheduler.schedule_next(user, now: NOW - 1.day)
    retrying = NotificationsHelper::FakeAdapter.new(Notifications::Slack::Result.failure("internal_error", retryable: true))
    dispatch(retrying, row)
    assert_equal 0, AnalyticsEvent.count, "a retry is not a failure yet"

    permanent = NotificationsHelper::FakeAdapter.new(Notifications::Slack::Result.failure("user_not_found", retryable: false))
    dispatch(permanent, row, now: row.reload.due_at + 1.minute)
    assert_equal({ "kind" => "daily_reminder", "channel" => "slack_dm", "code" => "user_not_found" }, only(:notification_failed).props)

    other = create_user
    other_row = Notifications::Scheduler.schedule_next(other, now: NOW - 1.day)
    dispatch(NotificationsHelper::FakeAdapter.new(delivers: false), other_row)
    assert_equal 0, events(:notification_sent).where(user_id: other.id).count, "an adapter that does not deliver sends nothing"
  end

  test "a finished quest records quest_completed once" do
    user = quest_user
    quest = make_quest(goal_key: "code_days", target: 2)
    with_feature(:quests) do
      code_at(user, WEEK_START, 900)
      code_at(user, WEEK_START + 1, 900)
      Quests::Evaluate.call(user)
      Quests::Evaluate.call(user)
    end

    assert_equal({ "goal_key" => "code_days" }, only(:quest_completed).props)
    assert_equal user.id, only(:quest_completed).user_id
    assert_equal 1, quest.completions.count
  end

  test "joining a crew records team_joined" do
    Flipper.enable(:team)
    founder = build_user
    Teams::Crew.create!(user: founder, name: "Night owls")
    token = Team.sole.invite_token
    Teams::Crew.join!(user: @user, token: token)

    assert_equal [ @user.id ], events(:team_joined).pluck(:user_id)
    assert_equal({}, only(:team_joined).props)
  end

  test "dropping a plinko ball records plinko_dropped once, a replay of the same drop nothing more" do
    Flipper.enable(:plinko)
    HourEntry.create!(user: @user, local_date: D[16], seconds: 3600, source: "manual", note: "plinko", idempotency_key: "p1")
    key = SecureRandom.hex(12)
    Plinko::Drop.call(user: @user, idempotency_key: key, now: NOW)
    Plinko::Drop.call(user: @user, idempotency_key: key, now: NOW)

    assert_equal 1, events(:plinko_dropped).count
    assert_equal({}, only(:plinko_dropped).props)
  end

  # ---- who is never measured ----

  test "a simulated player and a staff member record no product events" do
    sim = build_user(created_on: D[1])
    sim.update!(hca_uid: "sim!product-1")
    staff = build_user(created_on: D[1])
    ENV["ADMIN_HCA_UIDS"] = staff.hca_uid
    [ sim, staff ].each do |person|
      person.update!(pace_minutes: 30)
      ship = submit_ship(shippable_project(person))
      Ships::Reject.call(ship: ship, reviewer: @reviewer, reason: "no", now: NOW)
      Shop::ClaimSticker.call(user: person)
      Hours::Credit.call(user: person, seconds: 3600, source: "hackatime", idempotency_key: "h-#{person.id}", local_date: D[16])
      Game::Settle.call(person, through: Time.utc(2026, 11, 8, 12), source: StubHoursSource.new({ D[1] => 900 }))
    end

    assert_equal 0, AnalyticsEvent.count
  ensure
    ENV.delete("ADMIN_HCA_UIDS")
  end

  # ---- analytics never breaks the action ----

  test "when the write fails in production the ship decision, the purchase and the credit all still happen, and only the error class is logged" do
    verified!(@user)
    give_coins(@user, 500)
    ship = nil
    log = capture_log do
      production_mode do
        stub_method(Analytics::Tracker, :write, ->(*, **) { raise ActiveRecord::StatementInvalid, "PROBE-SQL-DETAIL" }) do
          ship = submit_ship(shippable_project)
          assert approve(ship).approved?
          assert_equal "tshirt", Shop::Purchase.call(user: @user, prize_key: "tshirt", idempotency_key: "k9").prize_key
          assert Hours::Credit.call(user: @user, seconds: 3600, source: "hackatime", idempotency_key: "h9", local_date: D[16]).created?
        end
      end
    end

    assert ship.reload.status_approved?
    assert_equal 0, AnalyticsEvent.count
    assert_includes log, "ActiveRecord::StatementInvalid"
    assert_no_match(/PROBE/, log)
  end

  test "when working an event out fails, the subscriber and the services swallow it, log the class and carry on" do
    ship = submit_ship(shippable_project)
    log = capture_log do
      stub_method(Analytics::Product, :nth, ->(*) { raise IOError, "PROBE-DETAIL" }) do
        assert approve(ship).approved?
        assert Ships::Withdraw.call(ship: submit_ship(shippable_project(from: 20)))
      end
      stub_method(Analytics::Product, :channel_of, ->(*) { raise IOError, "PROBE-DETAIL" }) do
        user = create_user
        row = Notifications::Scheduler.schedule_next(user, now: NOW - 1.day)
        summary = with_env("NOTIFICATIONS_ENABLED" => "true") do
          Notifications::Dispatcher.run(now: row.scheduled_for + 1.minute, adapter: NotificationsHelper::FakeAdapter.new)
        end
        assert_equal 1, summary.sent
      end
    end

    assert ship.reload.status_approved?
    assert_not_tracked :ship_approved
    assert_includes log, "IOError"
    assert_no_match(/PROBE/, log)
  end

  test "a typo in an event name still raises outside production, so it fails CI" do
    assert_raises(Analytics::Events::Invalid) { Analytics::Product.guard("x") { Analytics.track(:ship_aproved, user: @user) } }
  end

  test "every event this layer fires is declared, with only declared properties" do
    declared = Analytics::Events.names
    fired = File.read(Rails.root.join("app/services/analytics/product.rb")).scan(/Analytics\.track\(:(\w+)/).flatten.uniq
    assert_empty fired - declared
    assert_empty %w[ship_submitted ship_approved ship_rejected ship_withdrawn boss_hit boss_defeated order_placed purchase_refused first_hours_credited quick_day_reached
                    daily_goal_reached streak_extended streak_broken freeze_used pace_set notification_sent notification_failed nps_answered quest_completed
                    team_joined plinko_dropped] - fired # (the four order_* events are named by the order's action, and have their own test)
  end
end
