require "test_helper"
require_relative "../../support/coins_helper"
require_relative "../../support/ships_test_support"
require_relative "../../support/quests_helper"

# Every feature that can pay on a ship approval, at once, for one person: base coins, streak bonus (raised by the welcome-back
# boost), the crew bonus and a completed weekly quest. Each ledger row must exist exactly once with the right amount, however the
# subscribers are ordered, repeated, retried or broken, and whichever of two staff approves.
module AllBonusesWorld
  include CoinsHelper
  include ShipsTestSupport
  include QuestsHelper

  D = ->(day) { Date.new(2026, 11, day) }
  # Two days after the quest week ended: every day of the ship is settled.
  NOW = Time.utc(2026, 11, 14, 12)

  ALL_FLAGS = %i[team quests returning].freeze

  # The person (coded on 1 Nov, then nothing for 7 days, then back on 9, 10 and 11 Nov: a welcome-back window of 9 to 11 Nov,
  # three different coding days for the quest) and a crewmate who coded on 9 and 10 Nov. Returns [user, ship, mate, quest].
  def build_world
    user = quest_user(created_on: D[1])
    mate = quest_user(created_on: D[1])
    user.update_columns(slack_id: "U0ALLBONUS")
    project = make_project(user)
    code_at(user, D[1], 900, recorded_at: Time.utc(2026, 11, 1, 20))
    # Hackatime project on the entries too, so the ship's window counts them.
    HourEntry.where(user_id: user.id).update_all(hackatime_project: "space-farm")
    [ 9, 10, 11 ].each { |day| code_at(user, D[day], 3600, recorded_at: Time.utc(2026, 11, day, 20)) }
    HourEntry.where(user_id: user.id).update_all(hackatime_project: "space-farm")
    [ 9, 10 ].each { |day| code_at(mate, D[day], 1800, recorded_at: Time.utc(2026, 11, day, 20)) }

    team = Team.create!(invite_token: Team.new_token, invite_expires_at: 1.year.from_now)
    TeamMembership.create!(team: team, user: user, joined_at: Time.utc(2026, 10, 31))
    TeamMembership.create!(team: team, user: mate, joined_at: Time.utc(2026, 10, 31))

    # The quest week (6 to 12 Nov) is over by the time the ship is approved, which the admin form would refuse to create: saved as it was
    # when the admin set it, before the week began.
    Boss.find_by(starts_on: D[6]) || make_boss(starts_on: D[6])
    quest = Quest.new(starts_on: D[6], ends_on: D[12], goal_key: "code_days", reward_coins: 15)
    quest.target = 3
    quest.save!(validate: false)
    ship = submit_ship(project)
    [ user, ship, mate, quest ]
  end

  def ledger(user) = CoinTransaction.where(user_id: user.id).order(:id).pluck(:kind, :amount, :idempotency_key)

  def kinds(user) = CoinTransaction.where(user_id: user.id).group(:kind).count
end

class AllBonusesTest < ActiveSupport::TestCase
  include AllBonusesWorld

  setup do
    ALL_FLAGS.each { |flag| Flipper.enable(flag) }
    @reviewer = users(:onboarded)
    travel_to(NOW)
    @user, @ship, @mate, @quest = build_world
  end

  teardown { travel_back }

  def approve(ship = @ship, reviewer = @reviewer)
    Ships::Approve.call(ship: ship, reviewer: reviewer, approved_seconds: ship.coded_seconds, now: NOW)
  end

  test "one approval pays base, boosted streak bonus, crew bonus and quest reward, each once and with the right amount" do
    result = approve
    assert result.approved?
    assert_equal [], result.unsettled_dates

    # The boost: 9 to 11 Nov are inside the welcome-back window, so their streak bonus is at least the 10.3% floor.
    window = WelcomeBackWindow.find_by!(user_id: @user.id)
    assert_equal [ D[9], D[11] ], [ window.starts_on, window.ends_on ]
    boosted = DailyResult.where(user_id: @user.id, local_date: D[9]..D[11]).pluck(:bonus_bps)
    assert_equal [ 1030 ] * 3, boosted

    rows = CoinTransaction.where(user_id: @user.id)
    assert_equal({ "ship_approval" => 1, "streak_bonus" => 1, "team_bonus" => 1, "quest_reward" => 1 }, kinds(@user))

    # Base: 3.25 approved hours at 10 coins an hour = 32.5 -> floor of the whole base.
    base = rows.find_by!(kind: "ship_approval").amount
    assert_equal 32, base
    # Streak bonus: the floor on the three boosted days, the 5% first-day-of-streak ramp on 1 Nov, summed exactly and floored once.
    expected = Coins::ShipPayout.call(approved_seconds: @ship.coded_seconds, coded_seconds_by_date: @ship.daily_seconds_by_date.transform_keys(&:to_date),
                                      bonus_bps_by_date: DailyResult.where(user_id: @user.id, local_date: @ship.window_dates).to_h { |row| [ row.local_date, row.bonus_bps ] })
    assert_equal expected.base_coins, base
    assert_equal expected.bonus_coins, rows.find_by!(kind: "streak_bonus").amount
    assert_operator expected.bonus_coins, :>=, 3, "the boost raised the bonus above what the 5% to 8.1% ramp alone pays"

    # Crew bonus: 5% of the base coins of the days the crewmate also coded (9 and 10 Nov).
    team_row = rows.find_by!(kind: "team_bonus")
    assert_equal "team_bonus:ship:#{@ship.id}", team_row.idempotency_key
    assert_equal 2, TeamPayout.find_by!(ship_id: @ship.id).matched_days
    per_date = Coins::ShipPayout.call(approved_seconds: @ship.coded_seconds, coded_seconds_by_date: @ship.daily_seconds_by_date.transform_keys(&:to_date)).per_date
    assert_equal ((per_date[D[9]][:base_milli_coins] + per_date[D[10]][:base_milli_coins]) * 5 / 100 / 1000.0).floor, team_row.amount

    # Quest: the flat reward, linked to this ship, recorded as paid.
    quest_row = rows.find_by!(kind: "quest_reward")
    assert_equal [ 15, "quest:#{@quest.id}:user:#{@user.id}", @ship.id ], [ quest_row.amount, quest_row.idempotency_key, quest_row.reference_id ]
    assert_equal quest_row.id, QuestCompletion.find_by!(user_id: @user.id, quest_id: @quest.id).coin_transaction_id

    assert_equal rows.sum(:amount), Coins::Balance.total(@user)
    assert_equal 4, rows.count
    assert_equal 0, CoinTransaction.where(user_id: @mate.id).count, "the crewmate earns nothing from someone else's ship"
  end

  test "approving again, repeating the event and running every retry task pays nothing a second time" do
    approve
    first = ledger(@user)

    assert_not approve.approved?, "a second approval finds the ship already approved"
    2.times { ActiveSupport::Notifications.instrument("ship_approved.battletown", ship_id: @ship.id) }
    Teams::PayPending.scan(now: NOW)
    Quests::Evaluate.all(now: NOW)
    Game::Settle.call(@user, through: NOW)
    assert_equal first, ledger(@user)
    assert_equal 1, Notification.where(user_id: @user.id, kind: "ship_approved").count
  end

  test "the order of the subscribers does not matter: each payer alone gives the same rows as all of them" do
    approve
    reference = ledger(@user).map(&:first).sort

    # Replay the payers in every order on a fresh world after wiping the payouts: same rows, nothing doubled.
    orders = [ %i[quests team], %i[team quests] ]
    orders.each do |order|
      CoinTransaction.where(user_id: @user.id, kind: %w[team_bonus quest_reward]).delete_all
      TeamPayout.delete_all
      QuestCompletion.where(user_id: @user.id).update_all(coin_transaction_id: nil)
      payload = { ship_id: @ship.id }
      order.each { |payer| payer == :team ? Teams::Triggers.ship_approved(payload) : Quests::Triggers.ship_approved(payload) }
      assert_equal reference, ledger(@user).map(&:first).sort, "order #{order.inspect}"
    end
  end

  test "a subscriber that fails does not stop the others or undo the approval, and its retry task pays later" do
    result = with_replaced(Teams::PayShip, :call, ->(*) { raise "boom" }) { approve }
    assert result.approved?
    assert_equal "approved", @ship.reload.status
    assert_equal({ "ship_approval" => 1, "streak_bonus" => 1, "quest_reward" => 1 }, kinds(@user), "quest and Slack still ran; only the crew bonus is missing")
    assert_equal 1, Notification.where(user_id: @user.id, kind: "ship_approved").count
    assert_equal 0, TeamPayout.count

    assert_equal [ 1, 1 ], Teams::PayPending.scan(now: NOW).then { |scan| [ scan.scanned, scan.paid ] }
    assert_equal 1, kinds(@user)["team_bonus"]

    # And the other way round: the quest payer fails, the crew bonus and the message still happen, the dashboard evaluation repairs it.
    CoinTransaction.where(user_id: @user.id, kind: %w[team_bonus quest_reward]).delete_all
    TeamPayout.delete_all
    QuestCompletion.where(user_id: @user.id).update_all(coin_transaction_id: nil)
    with_replaced(Quests::Evaluate, :call, ->(*) { raise "boom" }) do
      ActiveSupport::Notifications.instrument("ship_approved.battletown", ship_id: @ship.id)
    end
    assert_equal({ "ship_approval" => 1, "streak_bonus" => 1, "team_bonus" => 1 }, kinds(@user))
    Quests::Evaluate.call(@user, now: NOW)
    assert_equal 1, kinds(@user)["quest_reward"]
  end

  test "a ship approved while its last day is still settling pays its crew bonus later, whole" do
    travel_to(Time.utc(2026, 11, 12, 1)) # 11 Nov settles at 06:00 on the 12th
    result = Ships::Approve.call(ship: @ship, reviewer: @reviewer, approved_seconds: @ship.coded_seconds, now: Time.utc(2026, 11, 12, 1))
    assert result.approved?
    assert_equal 0, TeamPayout.count, "waiting, not marked"
    assert_equal 0, kinds(@user)["team_bonus"].to_i

    travel_to(Time.utc(2026, 11, 12, 7))
    assert_equal 1, Teams::PayPending.scan(now: Time.utc(2026, 11, 12, 7)).paid
    assert_equal 2, TeamPayout.sole.matched_days
  end

  test "every flag off: the same approval pays only base and streak bonus" do
    ALL_FLAGS.each { |flag| Flipper.disable(flag) }
    approve
    assert_equal({ "ship_approval" => 1, "streak_bonus" => 1 }, kinds(@user))
    assert_equal 0, WelcomeBackWindow.count
    assert_equal 0, TeamPayout.count
  end
end

# Two staff approving the same ship at the same moment, on real connections (so outside a rolled-back transaction).
class AllBonusesConcurrencyTest < ActiveSupport::TestCase
  include AllBonusesWorld

  self.use_transactional_tests = false

  setup do
    ALL_FLAGS.each { |flag| Flipper.enable(flag) }
    travel_to(NOW)
    @user, @ship, @mate, @quest = build_world
    @reviewers = [ users(:onboarded), users(:new_user) ]
  end

  teardown do
    travel_back
    ALL_FLAGS.each { |flag| Flipper.disable(flag) }
    Team.where(id: TeamMembership.where(user_id: [ @user.id, @mate.id ]).select(:team_id)).delete_all
    User.where(id: [ @user.id, @mate.id ]).delete_all
    Quest.where(id: @quest.id).delete_all
    Boss.where(starts_on: D[6]).delete_all
  end

  test "two reviewers approving at once pay every bonus exactly once" do
    gate = Queue.new
    ready = Queue.new
    threads = @reviewers.map do |reviewer|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          gate.pop
          Ships::Approve.call(ship: Ship.find(@ship.id), reviewer: reviewer, approved_seconds: @ship.coded_seconds, now: NOW).status
        rescue StandardError => error
          error
        end
      end
    end
    2.times { Timeout.timeout(20) { ready.pop } }
    2.times { gate << true }
    outcomes = threads.map(&:value)

    assert_equal [ :approved, :unavailable ], outcomes.sort_by(&:to_s), outcomes.inspect
    assert_equal({ "ship_approval" => 1, "streak_bonus" => 1, "team_bonus" => 1, "quest_reward" => 1 }, kinds(@user))
  end
end
