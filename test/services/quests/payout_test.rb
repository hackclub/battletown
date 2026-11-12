require "test_helper"
require_relative "../../support/quests_helper"
require_relative "../../support/ships_test_support"

# The reward is held until the person's next approved ship. Real approvals through Ships::Approve, so the event the
# subscriber listens to is the real one.
class Quests::PayoutTest < ActiveSupport::TestCase
  include QuestsHelper
  include ShipsTestSupport

  FRI = QuestsHelper::WEEK_START
  SAT = FRI + 1
  SUN = FRI + 2
  APPROVED_AT = Time.utc(2026, 11, 17, 12)

  setup do
    travel_to QuestsHelper::NOW
    @user = quest_user
    @reviewer = users(:onboarded)
    @quest = make_quest(goal_key: "code_days", target: 2)
    @project = make_project(@user)
  end

  def at(day, hour = 12) = Time.utc(2026, 11, day, hour)

  # Two coded hours (Friday and Saturday) synced on the 14th, which finishes the 2-day quest at 14 Nov 09:00.
  def code_the_week
    code(@user, FRI, HOUR)
    code(@user, SAT, HOUR)
    HourEntry.where(user_id: @user.id).update_all(recorded_at: at(14, 9))
  end

  def approve(ship, now: APPROVED_AT)
    Ships::Approve.call(ship: ship, reviewer: @reviewer, approved_seconds: ship.coded_seconds, now: now)
  end

  def rewards = CoinTransaction.where(user_id: @user.id, kind: "quest_reward")

  def completion = QuestCompletion.find_by(user_id: @user.id, quest_id: @quest.id)

  test "a finished quest waits, then is paid with the next approved ship, once, and the ship's own coins are untouched" do
    with_feature(:quests) do
      code_the_week
      Quests::Evaluate.call(@user)
      assert_not completion.paid?
      assert_equal 0, rewards.count, "nothing is paid when the quest is completed"
      assert_equal 0, Coins::Balance.total(@user)

      ship = submit_ship(@project)
      result = approve(ship)

      assert_equal 1, rewards.count
      reward = rewards.first
      assert_equal [ 15, "quest:#{@quest.id}:user:#{@user.id}", "Ship", ship.id ], [ reward.amount, reward.idempotency_key, reward.reference_type, reward.reference_id ]
      assert completion.reload.paid?
      assert_equal reward.id, completion.coin_transaction_id
      assert_equal result.credit.base_coins + result.credit.bonus_coins, ship.reload.coin_breakdown[:total], "the ship's own coins are what Coins::ApproveShip wrote"
      assert_equal result.credit.base_coins + result.credit.bonus_coins + 15, Coins::Balance.total(@user)
    end
  end

  test "a double event and a repeated payout pay once" do
    with_feature(:quests) do
      code_the_week
      ship = submit_ship(@project)
      approve(ship)
      assert_equal 1, rewards.count

      2.times { ActiveSupport::Notifications.instrument("ship_approved.battletown", ship_id: ship.id) }
      2.times { Quests::Payout.call(@user) }
      Quests::Evaluate.call(@user)
      assert_equal 1, rewards.count
    end
  end

  test "an approval that happened before the quest was completed does not pay it; the next one does" do
    with_feature(:quests) do
      code(@user, FRI, HOUR)
      HourEntry.where(user_id: @user.id).update_all(recorded_at: at(13, 9))
      first = submit_ship(@project)
      approve(first, now: at(16, 9))
      code(@user, SAT, HOUR)
      HourEntry.where(user_id: @user.id, local_date: SAT).update_all(recorded_at: at(16, 12)) # finishes the quest after the approval

      Quests::Evaluate.call(@user, now: at(16, 13))
      assert completion
      assert_equal 0, rewards.count

      code(@user, SUN, HOUR)
      second = submit_ship(@project)
      approve(second, now: at(17, 12))
      assert_equal 1, rewards.count
      assert_equal second.id, rewards.first.reference_id
    end
  end

  test "turning the flag on later pays at the first look when a ship was already approved after the quest was really completed" do
    ship = nil
    without_feature(:quests) do
      code_the_week
      ship = submit_ship(@project)
      approve(ship, now: at(15, 9))
      assert_equal 0, QuestCompletion.count
    end

    with_feature(:quests) do
      Quests::Evaluate.call(@user, now: at(18, 9))
      assert_equal 1, rewards.count, "the goal held on the 14th, the ship was approved on the 15th"
      assert_equal ship.id, rewards.first.reference_id
    end
  end

  test "approving with the flag off creates no completion, pays nothing and sends the quest code nowhere" do
    without_feature(:quests) do
      code_the_week
      approve(submit_ship(@project))
      assert_equal 0, QuestCompletion.count
      assert_equal 0, rewards.count
    end
  end

  test "a rejected ship pays nothing" do
    with_feature(:quests) do
      code_the_week
      Quests::Evaluate.call(@user)
      ship = submit_ship(@project)
      Ships::Reject.call(ship: ship, reviewer: @reviewer, reason: "The repository is private")
      Quests::Payout.call(@user)
      assert_equal 0, rewards.count
      assert_not completion.paid?
    end
  end

  test "two waiting quests are both paid by one approval, each under its own key" do
    second = make_quest(starts_on: FRI + 7, goal_key: "add_project", target: nil)
    with_feature(:quests) do
      code_the_week
      QuestCompletion.create!(user: @user, quest: second, completed_at: at(14, 9))
      Quests::Evaluate.call(@user)
      approve(submit_ship(@project))

      assert_equal 2, rewards.count
      assert_equal [ "quest:#{@quest.id}:user:#{@user.id}", "quest:#{second.id}:user:#{@user.id}" ].sort, rewards.pluck(:idempotency_key).sort
    end
  end

  test "a failure in the quest subscriber never breaks the approval" do
    with_feature(:quests) do
      code_the_week
      ship = submit_ship(@project)
      result = with_replaced(Quests::Evaluate, :call, ->(*, **) { raise "boom" }) { approve(ship) }

      assert result.approved?
      assert_equal "approved", ship.reload.status
      assert_equal 0, rewards.count
      Quests::Evaluate.call(@user) # the next look pays it
      assert_equal 1, rewards.count
    end
  end

  test "the reward uses the quest's own coins and the ledger kind is a credit" do
    @quest.update_columns(reward_coins: 40)
    with_feature(:quests) do
      code_the_week
      approve(submit_ship(@project))
      assert_equal 40, rewards.first.amount
    end
    assert_includes CoinTransaction::CREDIT_KINDS, "quest_reward"
    assert_raises(ActiveRecord::RecordInvalid) { CoinTransaction.create!(user: @user, amount: -5, kind: "quest_reward", idempotency_key: "neg") }
  end

  test "the database refuses a quest_reward debit" do
    assert_raises(ActiveRecord::StatementInvalid) do
      CoinTransaction.new(user: @user, amount: -5, kind: "quest_reward", idempotency_key: "neg-db").save!(validate: false)
    end
  end
end
