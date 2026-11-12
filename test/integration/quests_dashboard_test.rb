require "test_helper"
require_relative "../support/quests_helper"
require_relative "../support/ships_test_support"

class QuestsDashboardTest < ActionDispatch::IntegrationTest
  include QuestsHelper
  include ShipsTestSupport

  FRI = QuestsHelper::WEEK_START
  SAT = FRI + 1

  setup do
    OmniAuth.config.test_mode = true
    travel_to QuestsHelper::NOW
    @user = users(:onboarded)
    @user.update_columns(time_zone: "UTC", created_at: Time.utc(2026, 11, 1, 12), signed_up_on: Date.new(2026, 11, 1))
    @quest = make_quest(goal_key: "code_days", target: 2)
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
  end

  def at(day, hour = 12) = Time.utc(2026, 11, day, hour)

  def sign_in_as(user)
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
  end

  def dashboard
    sign_in_as @user
    get dashboard_path
    assert_response :success
  end

  test "flag off: no card, no copy, no rows, even when the goal holds" do
    code_at(@user, FRI, 900, recorded_at: at(13, 9))
    code_at(@user, SAT, 900, recorded_at: at(14, 9))
    without_feature(:quests) do
      dashboard
      assert_no_match(/Weekly quest|quest-card|Code on 2 different days/, response.body)
      assert_equal 0, QuestCompletion.count
    end
  end

  test "flag on but no quest this week: no card" do
    @quest.destroy
    with_feature(:quests) do
      dashboard
      assert_no_match(/quest-card/, response.body)
    end
  end

  test "flag on: the card shows this week's quest, the person's own progress, the status chip and the reward" do
    code_at(@user, FRI, 900, recorded_at: at(13, 9))
    with_feature(:quests) do
      dashboard
      assert_select "section.quest-card" do
        assert_select "h2#quest-card-title", "Code on 2 different days"
        assert_select ".quest-card__chip", "In progress"
        assert_select "#quest-card-progress-text", "1 of 2 days"
        assert_select "progress#quest-card-progress[max='2'][value='1']"
        assert_select ".quest-card__reward-pill", "Reward: 15 coins"
        assert_select ".quest-card__message", /next approved ship/
      end
      assert_equal 0, QuestCompletion.count
    end
  end

  test "a finished quest shows Done with the reward waiting, then Paid after the next approved ship" do
    code(@user, FRI, HOUR)
    code(@user, SAT, HOUR)
    HourEntry.where(user_id: @user.id).update_all(recorded_at: at(14, 9))
    project = make_project(@user)
    with_feature(:quests) do
      dashboard
      assert_select ".quest-card__chip", "Done"
      assert_select ".quest-card__message", "Quest done! Your 15 coins arrive with your next approved ship."
      assert_select "#quest-card-progress-text", "2 of 2 days"
      assert_equal 1, QuestCompletion.count
      assert_equal 0, CoinTransaction.where(kind: "quest_reward").count

      ship = submit_ship(project)
      Ships::Approve.call(ship: ship, reviewer: users(:new_user), approved_seconds: ship.coded_seconds, now: at(17, 12))
      get dashboard_path
      assert_select ".quest-card__chip", "Paid"
      assert_select ".quest-card__message", /were paid with your approved ship/
      assert_equal 1, CoinTransaction.where(user_id: @user.id, kind: "quest_reward").count
    end
  end

  test "a finished quest from a week that is over stays on the card while its reward waits, and an unfinished one is not shown" do
    code_at(@user, FRI, 900, recorded_at: at(13, 9))
    code_at(@user, SAT, 900, recorded_at: at(14, 9))
    travel_to Time.utc(2026, 11, 21, 12) # the week is over, and so is the quest's checking... the grace days still apply
    with_feature(:quests) do
      dashboard
      assert_select ".quest-card__chip", "Done"
    end

    other = quest_user
    sign_in_as(other)
    with_feature(:quests) do
      get dashboard_path
      assert_no_match(/quest-card/, response.body, "someone who did not finish it sees nothing once the week is over")
    end
  end

  test "nothing about other people appears on the card" do
    other = quest_user
    other.update_columns(display_name: "Zebulon Quux")
    code_at(other, FRI, 3600, recorded_at: at(13, 9))
    code_at(other, SAT, 3600, recorded_at: at(14, 9))
    with_feature(:quests) do
      Quests::Evaluate.call(other)
      dashboard
      assert_no_match(/Zebulon|Quux/, response.body)
      assert_select "#quest-card-progress-text", "0 of 2 days"
    end
  end

  test "a failure while checking the quest never takes the dashboard down" do
    with_feature(:quests) do
      with_replaced(Quests::Evaluate, :call, ->(*, **) { raise "secret detail somebody@example.com" }) do
        dashboard
        assert_select "h1", /Welcome/
      end
    end
  end

  test "the page stays within a small number of queries with the card on" do
    code_at(@user, FRI, 900, recorded_at: at(13, 9))
    with_feature(:quests) do
      sign_in_as @user
      count = 0
      counter = ->(*, payload) { count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) || payload[:sql].match?(/\A\s*(BEGIN|COMMIT|SAVEPOINT|RELEASE)/i) }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get dashboard_path }
      assert_operator count, :<=, 45
    end
  end
end
