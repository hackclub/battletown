require "test_helper"
require_relative "../support/quests_helper"

class QuestTest < ActiveSupport::TestCase
  include QuestsHelper

  setup do
    travel_to QuestsHelper::NOW
    @boss = make_boss(starts_on: WEEK_START)
  end

  def build(**attrs) = Quest.new({ starts_on: WEEK_START, goal_key: "code_days", reward_coins: 15, goal_params: { "target" => 3 } }.merge(attrs))

  test "a valid quest takes its last day from the boss week and gives its copy from the goal" do
    quest = build
    assert quest.save, quest.errors.full_messages.to_sentence
    assert_equal WEEK_END, quest.ends_on
    assert_equal 3, quest.target
    assert_equal "Code on 3 different days", quest.title
    assert_match(/at least 15 minutes on 3 different days/, quest.description)
  end

  test "the week must be the first day of a boss week" do
    assert_not build(starts_on: WEEK_START + 1).valid?
    assert_includes build(starts_on: WEEK_START + 1).tap(&:valid?).errors[:starts_on].to_sentence, "first day of a boss week"
    assert_not build(starts_on: nil).valid?
    assert_not build(starts_on: Date.new(2026, 12, 4)).valid?, "no boss starts that day"
  end

  test "there is one quest per week" do
    build.save!
    duplicate = build(goal_key: "add_project", goal_params: {})
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:starts_on], "already has a quest"
    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
  end

  test "a week that is already over cannot be given a quest" do
    old = make_boss(starts_on: WEEK_START - 14)
    quest = build(starts_on: old.starts_on)
    assert_not quest.valid?
    assert_includes quest.errors[:starts_on].to_sentence, "already over"
  end

  test "the goal must be on the code's menu and on the config menu" do
    assert_not build(goal_key: "free_text").valid?
    assert_not build(goal_key: nil).valid?
    Quests::Goals::KEYS.each { |key| assert_includes Quests::Config.current.allowed_goals, key }

    Quests::Config.instance_variable_set(:@current, Quests::Config.current.with(allowed_goals: %w[add_project].freeze))
    assert_not build(goal_key: "code_days").valid?
    assert build(goal_key: "add_project", goal_params: {}).valid?
  ensure
    Quests::Config.reset!
  end

  test "the number must fit the goal: a whole number in range for goals that count, none for the others" do
    assert_not build(goal_params: {}).valid?
    assert_not build(goal_params: { "target" => 0 }).valid?
    assert_not build(goal_params: { "target" => 8 }).valid?
    assert_not build(goal_params: { "target" => "3" }).valid?
    assert build(goal_params: { "target" => 7 }).valid?
    assert_not build(goal_key: "streak_days", goal_params: { "target" => 1 }).valid?
    assert build(goal_key: "streak_days", goal_params: { "target" => 2 }).valid?

    assert_not build(goal_key: "ship_project", goal_params: { "target" => 2 }).valid?
    assert_not build(goal_key: "ship_project", goal_params: { "other" => 1 }).valid?
    assert build(goal_key: "ship_project", goal_params: {}).valid?
  end

  test "target= takes the form's text" do
    quest = build(goal_params: {})
    quest.target = "4"
    assert_equal({ "target" => 4 }, quest.goal_params)
    quest.target = ""
    assert_equal({}, quest.goal_params)
    quest.target = "four"
    assert_not quest.valid?
  end

  test "the reward is a whole number of coins from 1 up to the config maximum" do
    max = Quests::Config.current.max_reward_coins
    assert build(reward_coins: max).valid?
    assert_not build(reward_coins: max + 1).valid?
    assert_not build(reward_coins: 0).valid?
    assert_not build(reward_coins: -5).valid?
    assert_not build(reward_coins: nil).valid?
    assert_raises(ActiveRecord::StatementInvalid) { build(reward_coins: 1001).save!(validate: false) }
  end

  test "the database refuses a goal outside the menu and a non-object goal_params" do
    assert_raises(ActiveRecord::StatementInvalid) { build(goal_key: "free_text").save!(validate: false) }
    assert_raises(ActiveRecord::StatementInvalid) { build(goal_params: [ 1 ]).save!(validate: false) }
  end

  test "a quest can be changed until its week starts, and never afterwards" do
    quest = build.tap(&:save!)
    travel_to Time.utc(2026, 11, 12, 9) # Thursday 23:00 in UTC+14: the week has not begun anywhere yet
    assert_not quest.started?
    assert quest.update(reward_coins: 20)

    travel_to Time.utc(2026, 11, 12, 11) # Friday 01:00 in UTC+14: the week has begun somewhere
    assert quest.started?
    assert_not quest.update(reward_coins: 25)
    assert_includes quest.errors[:base], "This quest can't be changed once its week has started"
    assert_not quest.update(goal_key: "add_project", goal_params: {})
    assert_equal 20, quest.reload.reward_coins
  end

  test "the week cannot be moved" do
    quest = build.tap(&:save!)
    other = make_boss(starts_on: WEEK_START + 7)
    assert_not quest.update(starts_on: other.starts_on)
    assert_includes quest.errors[:base], "A quest's week can't be changed"
  end

  test "open_weeks lists boss weeks that are not over and have no quest" do
    later = make_boss(starts_on: WEEK_START + 7)
    old = make_boss(starts_on: WEEK_START - 14)
    assert_equal [ @boss.id, later.id ], Quest.open_weeks.pluck(:id)
    build.save!
    assert_equal [ later.id ], Quest.open_weeks.pluck(:id)
    assert_not_includes Quest.open_weeks.pluck(:id), old.id
  end

  test "stats are counts and coins over everyone, per quest" do
    quest = build.tap(&:save!)
    users = Array.new(3) { quest_user }
    entry = CoinTransaction.create!(user: users[0], amount: 15, kind: "quest_reward", idempotency_key: "q-#{quest.id}")
    QuestCompletion.create!(user: users[0], quest: quest, completed_at: Time.current, coin_transaction: entry)
    QuestCompletion.create!(user: users[1], quest: quest, completed_at: Time.current)

    assert_equal({ completed: 2, paid: 1, coins: 15 }, Quest.stats([ quest ])[quest.id])
    assert_equal({ completed: 0, paid: 0, coins: 0 }, Quest.stats([ quest ])[quest.id + 1000])
  end

  test "for_date and covering find the quest for a boss week day" do
    quest = build.tap(&:save!)
    assert_equal quest, Quest.for_date(WEEK_START)
    assert_equal quest, Quest.for_date(WEEK_END)
    assert_nil Quest.for_date(WEEK_END + 1)
    assert_nil Quest.for_date(WEEK_START - 1)
  end

  test "deleting a quest or a user removes the completions by the database" do
    quest = build.tap(&:save!)
    user = quest_user
    QuestCompletion.create!(user: user, quest: quest, completed_at: Time.current)
    User.where(id: user.id).delete_all
    assert_equal 0, QuestCompletion.count

    other = quest_user
    QuestCompletion.create!(user: other, quest: quest, completed_at: Time.current)
    Quest.where(id: quest.id).delete_all
    assert_equal 0, QuestCompletion.count
  end
end
