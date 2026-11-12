require "test_helper"
require_relative "../../support/coins_helper"
require_relative "../../support/ships_test_support"

class Ships::ApproveTest < ActiveSupport::TestCase
  include CoinsHelper
  include ShipsTestSupport

  D = ->(day) { Date.new(2026, 11, day) }
  NOW = Time.utc(2026, 11, 10, 12)

  setup do
    @user = build_user(created_on: D[1])
    @reviewer = users(:onboarded)
    @project = make_project(@user)
  end

  # A submitted ship over Nov 1 to Nov 3, one hour each day (streak days 1, 2, 3).
  def three_hour_ship(project = @project)
    (1..3).each { |day| code(@user, D[day], HOUR) }
    submit_ship(project)
  end

  def approve(ship, hours: nil, now: NOW)
    Ships::Approve.call(ship: ship, reviewer: @reviewer, approved_seconds: Ships::Approve.seconds_from_hours(ship, hours), now: now)
  end

  def ledger = CoinTransaction.where(user_id: @user.id).order(:id)

  def events(name)
    captured = []
    subscriber = ActiveSupport::Notifications.subscribe(name) { |*args| captured << args.last }
    yield
    captured
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  test "approving credits base and streak bonus coins once and records the review" do
    ship = three_hour_ship
    result = nil
    payloads = events("ship_approved.battletown") { result = approve(ship) }

    assert result.approved?
    ship.reload
    assert_equal "approved", ship.status
    assert_equal 3 * HOUR, ship.approved_seconds
    assert_equal @reviewer, ship.reviewer
    assert_equal NOW, ship.reviewed_at
    assert_equal [ 30, 2 ], [ result.credit.base_coins, result.credit.bonus_coins ]
    assert_equal({ base: 30, bonus: 2, total: 32 }, ship.coin_breakdown)
    assert_equal [ "ship_approval", "streak_bonus" ], ledger.map(&:kind)
    assert_equal [ [ "Ship", ship.id ] ] * 2, ledger.map { |row| [ row.reference_type, row.reference_id ] }
    assert_equal 32, Coins::Balance.total(@user)
    assert_nil ship.payout_note
    assert_equal [ { ship_id: ship.id } ], payloads
  end

  test "approving again (a double click or a second admin) changes and credits nothing" do
    ship = three_hour_ship
    stale = Ship.find(ship.id) # a page that was loaded before the first click
    approve(ship)
    payloads = events("ship_approved.battletown") { assert approve(stale).unavailable? }
    assert_empty payloads
    assert_equal 2, ledger.count
    assert_equal 32, Coins::Balance.total(@user)
    assert_equal "approved", ship.reload.status
  end

  test "a lowered approval pays for fewer hours and approved hours are what is stored" do
    ship = three_hour_ship
    approve(ship, hours: "2")
    assert_equal 2 * HOUR, ship.reload.approved_seconds
    assert_equal 20, ship.coin_breakdown[:base]
  end

  test "approved hours are bounded: above zero, a step multiple, and never above the coded time" do
    ship = three_hour_ship
    [ "0", "-1", "3.25", "3.0001", "1.1", "0.1", "abc", "1,5" ].each do |text|
      assert_raises(Ships::Approve::Invalid, text) { approve(ship, hours: text) }
    end
    assert_equal 0, ledger.count
    assert_equal "submitted", ship.reload.status
    assert_equal 2700, Ships::Approve.seconds_from_hours(ship, "0.75")
  end

  test "the whole coded time may be approved even when it is not a step multiple" do
    code(@user, D[1], 3777)
    ship = submit_ship(@project)
    assert_equal 3777, ship.coded_seconds
    approve(ship)
    assert_equal 3777, ship.reload.approved_seconds
  end

  test "the database also refuses approved seconds above the coded time" do
    ship = three_hour_ship
    assert_raises(ActiveRecord::StatementInvalid) do
      ActiveRecord::Base.transaction(requires_new: true) do
        ship.update_columns(status: "approved", approved_seconds: ship.coded_seconds + 1, reviewed_at: NOW)
      end
    end
  end

  test "an unverified user gets the coins credited (they stay locked in the shop task, not here)" do
    assert @user.verification_needs_submission?
    approve(three_hour_ship)
    assert_equal 32, Coins::Balance.total(@user)
  end

  test "hours past the deflation threshold since the previous ship earn the lower rate" do
    (1..2).each { |day| code(@user, D[day], 4 * HOUR) }
    ship = submit_ship(@project)
    result = approve(ship)
    assert_equal 6 * 10 + 2 * 8, result.credit.base_coins
  end

  test "streak days still inside the grace period earn no bonus: reported before and after, and noted on the ship" do
    ship = three_hour_ship
    now = Time.utc(2026, 11, 3, 12) # Nov 3 settles at Nov 4 06:00
    assert_equal [ D[3] ], Ships::Approve.unsettled_dates(ship, now: now)
    assert_empty Ships::Approve.unsettled_dates(ship, now: NOW)

    result = approve(ship, now: now)
    assert_equal [ D[3] ], result.unsettled_dates
    assert_equal 30, result.credit.base_coins
    assert_match(/2026-11-03/, ship.reload.payout_note)
    assert_match(/not final/, ship.payout_note)
  end

  test "the payout follows the ship's snapshot, not the live ledger or the current links" do
    ship = three_hour_ship
    @project.hackatime_links.destroy_all
    HourEntry.where(user_id: @user.id).delete_all
    result = approve(ship)
    assert_equal 30, result.credit.base_coins
  end

  test "a failure after the credit rolls the credit back with the status change" do
    ship = three_hour_ship
    ship.define_singleton_method(:update!) { |*| raise ActiveRecord::RecordInvalid }
    assert_raises(ActiveRecord::RecordInvalid) { approve(ship) }
    assert_equal 0, ledger.count
    assert_equal "submitted", ship.reload.status
  end

  test "a withdrawn ship cannot be approved" do
    ship = three_hour_ship
    Ships::Withdraw.call(ship: ship)
    assert approve(Ship.find(ship.id)).unavailable?
    assert_equal 0, ledger.count
  end

  test "rejecting records the reason, credits nothing and emits the event with the ship id only" do
    ship = three_hour_ship
    reason = Ships::Reject.reason_from(preset: Ships::Config.current.rejection_reasons.first, note: "Make the repo public.")
    result = nil
    payloads = events("ship_rejected.battletown") { result = Ships::Reject.call(ship: ship, reviewer: @reviewer, reason: reason) }

    assert result.rejected?
    ship.reload
    assert_equal "rejected", ship.status
    assert_equal reason, ship.rejection_reason
    assert_equal @reviewer, ship.reviewer
    assert_equal 0, ledger.count
    assert_equal [ { ship_id: ship.id } ], payloads
    assert_equal :unavailable, Ships::Reject.call(ship: ship, reviewer: @reviewer, reason: "again").status
  end

  test "staff cannot approve or reject their own ship, and nothing changes" do
    ship = three_hour_ship
    error = assert_raises(Ships::Approve::OwnShip) { Ships::Approve.call(ship: ship, reviewer: @user, approved_seconds: ship.coded_seconds, now: NOW) }
    assert_kind_of Ships::Approve::Invalid, error
    assert_match(/own ship/, error.message)
    assert_raises(Ships::Reject::OwnShip) { Ships::Reject.call(ship: ship, reviewer: @user, reason: "Not good enough", now: NOW) }
    assert_kind_of Ships::Reject::Invalid, Ships::Reject::OwnShip.new

    assert_equal "submitted", ship.reload.status
    assert_nil ship.reviewer
    assert_equal 0, ledger.count
  end

  test "a rejection reason is a preset and/or free text of at most 300 characters" do
    preset = Ships::Config.current.rejection_reasons.first
    assert_equal preset, Ships::Reject.reason_from(preset: preset, note: "")
    assert_equal "Hello", Ships::Reject.reason_from(preset: "", note: " Hello ")
    assert_equal "Hello", Ships::Reject.reason_from(preset: "not a preset", note: "Hello"), "an unknown preset is ignored"
    assert_raises(Ships::Reject::Invalid) { Ships::Reject.reason_from(preset: "", note: "  ") }
    assert_raises(Ships::Reject::Invalid) { Ships::Reject.reason_from(preset: "", note: "x" * 301) }
    assert_raises(Ships::Reject::Invalid) { Ships::Reject.reason_from(preset: preset, note: "x" * 300) }
    assert_equal 300, Ships::Reject.reason_from(preset: "", note: "x" * 300).length
  end

  test "events carry ids only, never a name or an email" do
    @user.update_columns(display_name: "Secret Person", email: "secret@example.com")
    ship = three_hour_ship
    payloads = events("ship_approved.battletown") { approve(ship) }
    assert_equal [ :ship_id ], payloads.first.keys
    assert_not_includes payloads.to_s, "Secret"
    assert_not_includes payloads.to_s, "secret@example.com"
  end
end
