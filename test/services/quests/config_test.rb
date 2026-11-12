require "test_helper"

class Quests::ConfigTest < ActiveSupport::TestCase
  RAW = {
    default_reward_coins: 15, max_reward_coins: 40, allowed_goals: %w[code_days add_project], evaluate_grace_days: 3,
    goals: { code_days: { title: "Code on %{target} days", description: "At least %{minutes} minutes.", unit: "day", target: { min: 1, max: 7, default: 3 } },
             add_project: { title: "Add a project", description: "Add one." } }
  }.freeze

  test "the shipped config has a 15 coin default, a 40 coin ceiling and every goal on the menu" do
    config = Quests::Config.current
    assert_equal [ 15, 40, 3 ], [ config.default_reward_coins, config.max_reward_coins, config.grace_days ]
    assert_equal Quests::Goals::KEYS.sort, config.allowed_goals.sort
    assert_equal Quests::Goals::KEYS.sort, config.goals.keys.sort
    assert_equal 15, config.quick_minutes
    assert_operator config.max_reward_coins, :<=, Quest::REWARD_CEILING
  end

  test "goal copy fills in the number and the minutes" do
    goal = Quests::Config.from_hash(RAW).goal("code_days")
    assert_equal "Code on 5 days", goal.title_for(5, 15)
    assert_equal "At least 15 minutes.", goal.description_for(5, 15)
    assert goal.targeted?
    assert_not Quests::Config.from_hash(RAW).goal("add_project").targeted?
  end

  test "a bad config fails loudly" do
    assert_raises(ArgumentError) { Quests::Config.from_hash(RAW.merge(default_reward_coins: 50)) }
    assert_raises(ArgumentError) { Quests::Config.from_hash(RAW.merge(max_reward_coins: 5000, default_reward_coins: 5)) }
    assert_raises(ArgumentError) { Quests::Config.from_hash(RAW.merge(allowed_goals: %w[free_text])) }
    assert_raises(ArgumentError) { Quests::Config.from_hash(RAW.merge(allowed_goals: [])) }
    assert_raises(ArgumentError) { Quests::Config.from_hash(RAW.merge(allowed_goals: %w[ship_project])) }
    assert_raises(ArgumentError) { Quests::Config.from_hash(RAW.merge(evaluate_grace_days: -1)) }
  end
end
