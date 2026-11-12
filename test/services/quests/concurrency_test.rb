require "test_helper"
require_relative "../../support/quests_helper"
require_relative "../../support/ships_test_support"

# Real threads on real connections, so these cannot run inside a rolled-back transaction. Each test builds its own rows
# and deletes them at the end (the database cascades from the user and the quest).
class Quests::ConcurrencyTest < ActiveSupport::TestCase
  include QuestsHelper
  include ShipsTestSupport

  self.use_transactional_tests = false

  FRI = QuestsHelper::WEEK_START

  setup do
    travel_to QuestsHelper::NOW
    @user = quest_user
    @quest = make_quest(goal_key: "code_days", target: 2)
    @project = make_project(@user)
    Flipper.enable(:quests)
  end

  teardown do
    Flipper.disable(:quests)
    User.where(id: @user.id).delete_all
    Quest.where(id: @quest.id).delete_all
    Boss.where(starts_on: FRI).delete_all
  end

  def race(*blocks)
    gate = Queue.new
    ready = Queue.new
    threads = blocks.map do |block|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          gate.pop
          [ :ok, block.call ]
        rescue StandardError => error
          [ :error, error ]
        end
      end
    end
    blocks.size.times { Timeout.timeout(20) { ready.pop } }
    blocks.size.times { gate << true }
    threads.map(&:value)
  end

  def approved_ship!
    Ship.create!(user: @user, project: @project, status: "approved", description: "Built it", repo_url: REPO, coded_seconds: 3600, approved_seconds: 3600,
                 window_start_date: FRI, window_end_date: FRI, daily_seconds: { FRI.iso8601 => 3600 }, submitted_at: QuestsHelper::NOW,
                 reviewed_at: QuestsHelper::NOW + 1.hour)
  end

  def rewards = CoinTransaction.where(user_id: @user.id, kind: "quest_reward")

  test "a payout, a repeated event and an evaluation at once pay one waiting reward exactly once" do
    QuestCompletion.create!(user: @user, quest: @quest, completed_at: QuestsHelper::NOW - 1.day)
    ship = approved_ship!

    pay = -> { Quests::Payout.call(User.find(@user.id)) }
    event = -> { ActiveSupport::Notifications.instrument("ship_approved.battletown", ship_id: ship.id) }
    evaluate = -> { Quests::Evaluate.call(User.find(@user.id)) }
    outcomes = race(pay, event, evaluate)

    assert(outcomes.all? { |kind, _| kind == :ok }, outcomes.map(&:last).inspect)
    assert_equal 1, rewards.count
    assert_equal 15, Coins::Balance.total(@user)
    assert QuestCompletion.find_by!(user_id: @user.id).paid?
  end

  test "evaluating the same finished goal from many requests at once records one completion and pays once" do
    code_at(@user, FRI, 900, recorded_at: QuestsHelper::NOW - 2.days)
    code_at(@user, FRI + 1, 900, recorded_at: QuestsHelper::NOW - 1.day)
    approved_ship!

    evaluate = -> { Quests::Evaluate.call(User.find(@user.id)) }
    outcomes = race(evaluate, evaluate, evaluate)

    assert(outcomes.all? { |kind, _| kind == :ok }, outcomes.map(&:last).inspect)
    assert_equal 1, QuestCompletion.where(user_id: @user.id).count
    assert_equal 1, outcomes.sum { |_, recorded| recorded.size }, "exactly one caller reports it as new"
    assert_equal 1, rewards.count
  end
end
