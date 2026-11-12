require "test_helper"
require_relative "../../support/coins_helper"
require_relative "../../support/ships_test_support"

# The crew bonus at ship approval: paid once per ship, on days a crewmate also coded, under the flag.
class Teams::PayShipTest < ActiveSupport::TestCase
  include CoinsHelper
  include ShipsTestSupport

  D = ->(day) { Date.new(2026, 11, day) }
  NOW = Time.utc(2026, 11, 10, 12)
  JOINED = Time.utc(2026, 10, 31, 9)

  setup do
    Flipper.enable(:team)
    @user = build_user(created_on: D[1])
    @mate = build_user(created_on: D[1])
    @reviewer = users(:onboarded)
    @team = Team.create!(invite_token: Team.new_token, invite_expires_at: 1.day.from_now)
    @mine = TeamMembership.create!(team: @team, user: @user, joined_at: JOINED)
    @theirs = TeamMembership.create!(team: @team, user: @mate, joined_at: JOINED)
    @project = make_project(@user)
  end

  # Four hours on each of Nov 1, 2 and 3 (base coins 40, 36, 8h of deflation: 32), one ship.
  def ship_of_three_days
    (1..3).each { |day| code(@user, D[day], 4 * HOUR) }
    submit_ship(@project)
  end

  def approve(ship, now: NOW)
    Ships::Approve.call(ship: ship, reviewer: @reviewer, approved_seconds: ship.coded_seconds, now: now)
  end

  # Replaces Teams::PayShip.call for the block (restored afterwards). The replacement receives the original as its first argument.
  def with_pay_ship(replacement)
    original = Teams::PayShip.method(:call)
    Teams::PayShip.define_singleton_method(:call) { |*args, **opts| replacement.call(original, *args, **opts) }
    yield
  ensure
    Teams::PayShip.define_singleton_method(:call, original)
  end

  def team_rows(user = @user) = CoinTransaction.where(user_id: user.id, kind: "team_bonus")

  test "approving a ship pays the crew bonus on the days a crewmate also coded, as its own ledger row" do
    code(@mate, D[1], 900)
    code(@mate, D[2], 2 * HOUR)
    ship = ship_of_three_days
    approve(ship)

    row = team_rows.sole
    assert_equal 3, row.amount # 40 coins and 36 coins on the two matched days, 5% of 76 = 3.8, floored
    assert_equal "team_bonus:ship:#{ship.id}", row.idempotency_key
    assert_equal [ "Ship", ship.id ], [ row.reference_type, row.reference_id ]
    payout = TeamPayout.sole
    assert_equal [ @user.id, ship.id, @team.id, 3, 2 ], [ payout.user_id, payout.ship_id, payout.team_id, payout.coins, payout.matched_days ]
    assert_empty team_rows(@mate), "the crewmate earned nothing: their own ships pay their own bonus"
  end

  test "the crew bonus sits next to the base and the streak bonus and changes neither" do
    code(@mate, D[1], HOUR)
    ship = ship_of_three_days
    approve(ship)

    kinds = CoinTransaction.where(user_id: @user.id).order(:id).pluck(:kind)
    assert_equal %w[ship_approval streak_bonus team_bonus], kinds
    breakdown = ship.reload.coin_breakdown
    assert_equal %i[base bonus total], breakdown.keys, "the ship breakdown still reads base and streak only"
    assert_equal breakdown[:total] + team_rows.sole.amount, Coins::Balance.total(@user)
    assert_equal 2, team_rows.sole.amount # 40 coins x 5%
  end

  test "paying the same ship again (a duplicate event, a retry) credits nothing more" do
    code(@mate, D[1], HOUR)
    ship = ship_of_three_days
    approve(ship)

    again = Teams::PayShip.call(ship.reload)
    ActiveSupport::Notifications.instrument("ship_approved.battletown", ship_id: ship.id)
    assert_equal :already_paid, again.status
    assert_equal 1, team_rows.count
    assert_equal 1, TeamPayout.count
  end

  test "a day nobody else coded pays 0: a marker is written but no ledger row, and a later look never pays it" do
    ship = ship_of_three_days
    approve(ship)
    assert_equal [ 0, 0 ], [ team_rows.count, TeamPayout.sole.coins ]

    code(@mate, D[1], HOUR) # their hours arrive afterwards
    assert_equal :already_paid, Teams::PayShip.call(ship.reload).status
    assert_equal 0, team_rows.count
    assert_equal 0, Teams::PayPending.scan(now: NOW).scanned
  end

  test "someone who is not in a crew gets nothing and nothing is written" do
    @mine.destroy!
    code(@mate, D[1], HOUR)
    ship = ship_of_three_days
    approve(ship)

    assert_equal 0, TeamPayout.count
    assert_equal 0, team_rows.count
  end

  test "leaving the crew before the payout means nothing to pay" do
    code(@mate, D[1], HOUR)
    ship = ship_of_three_days
    without_feature(:team) { approve(ship) }
    @mine.destroy!

    assert_equal :no_crew, Teams::PayShip.call(ship.reload).status
    assert_equal 0, TeamPayout.count
  end

  test "a ship that is not approved pays nothing" do
    ship = ship_of_three_days
    assert_equal :not_approved, Teams::PayShip.call(ship).status
    assert_equal 0, TeamPayout.count
  end

  test "hours a crewmate coded before they signed up do not match" do
    late = build_user(created_on: D[5])
    @theirs.destroy!
    TeamMembership.create!(team: @team, user: late, joined_at: Time.utc(2026, 11, 5, 13))
    code(late, D[1], 2 * HOUR) # in the ledger, before their sign-up date: counts for nothing
    ship = ship_of_three_days
    approve(ship)

    assert_equal 0, team_rows.count
    assert_equal 0, TeamPayout.sole.matched_days
  end

  test "only days after both of you were in the crew for the whole date match" do
    @theirs.update!(joined_at: Time.utc(2026, 11, 2, 15)) # in for the 3rd, not the 2nd
    code(@mate, D[2], 2 * HOUR)
    code(@mate, D[3], 2 * HOUR)
    ship = ship_of_three_days
    approve(ship)

    assert_equal 1, TeamPayout.sole.matched_days
    assert_equal 1, team_rows.sole.amount # 8 hours in: the 3rd day is deflated, 32 coins x 5% = 1.6
  end

  test "days that are not settled yet earn no crew bonus (the same rule as the streak bonus)" do
    code(@mate, D[1], HOUR)
    code(@mate, D[3], HOUR)
    ship = ship_of_three_days
    approve(ship)
    TeamPayout.delete_all
    CoinTransaction.where(kind: "team_bonus").delete_all

    # Nov 3 settles on Nov 4 at 06:00 UTC for a UTC user.
    result = Teams::PayShip.call(ship.reload, now: Time.utc(2026, 11, 3, 12))
    assert_equal 1, result.matched_days
  end

  test "the flag off: no payout, no marker, no ledger row, nothing read" do
    code(@mate, D[1], HOUR)
    ship = ship_of_three_days
    without_feature(:team) do
      approve(ship)
      assert_equal :disabled, Teams::PayShip.call(ship.reload).status
      assert_equal 0, Teams::PayPending.scan(now: NOW).scanned
    end

    assert_equal 0, TeamPayout.count
    assert_equal 0, CoinTransaction.where(kind: "team_bonus").count
  end

  test "the retry scan pays an approval whose payout did not run, once" do
    code(@mate, D[1], HOUR)
    ship = ship_of_three_days
    without_feature(:team) { approve(ship) }

    result = Teams::PayPending.scan(now: NOW)
    assert_equal [ 1, 1 ], [ result.scanned, result.paid ]
    assert_equal 1, team_rows.count
    assert_equal [ 0, 0 ], (r = Teams::PayPending.scan(now: NOW)).then { [ r.scanned, r.paid ] }
    assert_equal 1, team_rows.count
  end

  test "the retry scan leaves old approvals alone" do
    code(@mate, D[1], HOUR)
    ship = ship_of_three_days
    without_feature(:team) { approve(ship) }

    assert_equal 0, Teams::PayPending.scan(now: NOW + 10.days).scanned
    assert_equal 0, TeamPayout.count
  end

  test "a failing payout never breaks the approval and is picked up by the scan" do
    code(@mate, D[1], HOUR)
    ship = ship_of_three_days
    with_pay_ship(->(*) { raise "boom" }) { approve(ship) }

    assert_equal "approved", ship.reload.status
    assert_equal 0, TeamPayout.count
    assert_equal 1, Teams::PayPending.scan(now: NOW).paid
  end

  test "one bad ship does not stop the scan" do
    mate_project = make_project(@mate, name: "Moon Farm", hackatime: "moon-farm")
    code(@mate, D[1], 4 * HOUR, hackatime: "moon-farm")
    code(@user, D[1], HOUR)
    mine = submit_ship(@project)
    theirs = submit_ship(mate_project)
    without_feature(:team) do
      approve(mine)
      Ships::Approve.call(ship: theirs, reviewer: @reviewer, approved_seconds: theirs.coded_seconds, now: NOW)
    end

    first = true
    failing_once = lambda do |real, *args, **opts|
      if first
        first = false
        raise "boom"
      end
      real.call(*args, **opts)
    end
    with_pay_ship(failing_once) { assert_equal 1, Teams::PayPending.scan(now: NOW).paid }
    assert_equal 1, Teams::PayPending.scan(now: NOW).paid, "the one that failed is paid on the next run"
  end
end
