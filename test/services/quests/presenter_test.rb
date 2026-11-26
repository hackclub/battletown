require "test_helper"
require_relative "../../support/quests_helper"
require_relative "../../support/ships_test_support"

# What the quest card says (Quests::Presenter): this week's quest, the person's own progress, the status chip and the reward.
class Quests::PresenterTest < ActiveSupport::TestCase
  include QuestsHelper
  include ShipsTestSupport

  FRI = QuestsHelper::WEEK_START
  SAT = FRI + 1

  setup do
    travel_to QuestsHelper::NOW
    @user = quest_user
    @quest = make_quest(goal_key: "code_days", target: 2)
  end

  def at(day, hour = 12) = Time.utc(2026, 11, day, hour)

  def card(user = @user) = Quests::Presenter.new(user: user)

  test "no quest this week: no card" do
    @quest.destroy
    with_feature(:quests) do
      assert_not card.visible?
    end
  end

  test "the card shows this week's quest, the person's own progress, the status chip and the reward" do
    code_at(@user, FRI, 900, recorded_at: at(13, 9))
    with_feature(:quests) do
      card = card()
      assert card.visible?
      assert_equal "Code on 2 different days", card.title
      assert_equal "In progress", card.chip_text
      assert_equal "1 of 2 days", card.progress_text
      assert_equal [ 2, 1 ], [ card.target, card.progress_value ]
      assert_equal "15 coins", card.reward_text
      assert_match(/next approved ship/, card.message)
      assert_equal 0, QuestCompletion.count
    end
  end

  test "a finished quest shows Done with the reward waiting, then Paid after the next approved ship" do
    code(@user, FRI, HOUR)
    code(@user, SAT, HOUR)
    HourEntry.where(user_id: @user.id).update_all(recorded_at: at(14, 9))
    project = make_project(@user)
    with_feature(:quests) do
      Quests::Evaluate.call(@user)
      card = card()
      assert_equal "Done", card.chip_text
      assert_equal "Quest done! Your 15 coins arrive with your next approved ship.", card.message
      assert_equal "2 of 2 days", card.progress_text
      assert_equal 1, QuestCompletion.count
      assert_equal 0, CoinTransaction.where(kind: "quest_reward").count

      ship = submit_ship(project)
      Ships::Approve.call(ship: ship, reviewer: users(:new_user), approved_seconds: ship.coded_seconds, now: at(17, 12))
      card = card()
      assert_equal "Paid", card.chip_text
      assert_match(/were paid with your approved ship/, card.message)
      assert_equal 1, CoinTransaction.where(user_id: @user.id, kind: "quest_reward").count
    end
  end

  test "a finished quest from a week that is over stays on the card while its reward waits, and an unfinished one is not shown" do
    code_at(@user, FRI, 900, recorded_at: at(13, 9))
    code_at(@user, SAT, 900, recorded_at: at(14, 9))
    with_feature(:quests) do
      Quests::Evaluate.call(@user)
      travel_to Time.utc(2026, 11, 21, 12) # the week is over, and so is the quest's checking... the grace days still apply
      card = card()
      assert card.visible?
      assert_equal "Done", card.chip_text

      assert_not card(quest_user).visible?, "someone who did not finish it sees nothing once the week is over"
    end
  end

  test "nothing about other people appears on the card" do
    other = quest_user
    other.update_columns(display_name: "Zebulon Quux")
    code_at(other, FRI, 3600, recorded_at: at(13, 9))
    code_at(other, SAT, 3600, recorded_at: at(14, 9))
    with_feature(:quests) do
      Quests::Evaluate.call(other)
      card = card()
      words = [ card.title, card.description, card.reward_text, card.chip_text, card.progress_text, card.message, card.days_left_text ].join(" ")
      assert_no_match(/Zebulon|Quux/, words)
      assert_equal "0 of 2 days", card.progress_text
      assert_equal "In progress", card.chip_text
    end
  end

  test "building the card and reading all of it stays within a small number of queries" do
    code_at(@user, FRI, 900, recorded_at: at(13, 9))
    with_feature(:quests) do
      count = 0
      counter = ->(*, payload) { count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) || payload[:sql].match?(/\A\s*(BEGIN|COMMIT|SAVEPOINT|RELEASE)/i) }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        card = card()
        [ card.visible?, card.title, card.description, card.reward_text, card.chip_text, card.chip_variant, card.progress_text, card.progress_value,
          card.target, card.message, card.days_left_text ]
      end
      assert_operator count, :<=, 5
    end
  end
end
