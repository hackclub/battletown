require "test_helper"
require "rake"
require_relative "../../support/quests_helper"

class Quests::EvaluateTest < ActiveSupport::TestCase
  include QuestsHelper

  FRI = QuestsHelper::WEEK_START
  SAT = FRI + 1

  setup do
    travel_to QuestsHelper::NOW
    @user = quest_user
    @quest = make_quest(goal_key: "code_days", target: 2)
  end

  def at(day, hour = 12) = Time.utc(2026, 11, day, hour)

  def finish_goal
    code_at(@user, FRI, 900, recorded_at: at(13, 9))
    code_at(@user, SAT, 900, recorded_at: at(14, 9))
  end

  test "records a finished quest once, stamped with the moment the goal first held (not now)" do
    with_feature(:quests) do
      finish_goal
      recorded = Quests::Evaluate.call(@user)

      assert_equal [ @quest.id ], recorded.map(&:quest_id)
      completion = QuestCompletion.find_by!(user_id: @user.id, quest_id: @quest.id)
      assert_equal at(14, 9), completion.completed_at
      assert_not completion.paid?

      assert_empty Quests::Evaluate.call(@user), "a second call records nothing"
      assert_equal 1, QuestCompletion.where(user_id: @user.id).count
      assert_equal at(14, 9), completion.reload.completed_at
    end
  end

  test "an unfinished quest records nothing and a later call finishes it" do
    with_feature(:quests) do
      code_at(@user, FRI, 900, recorded_at: at(13, 9))
      assert_empty Quests::Evaluate.call(@user)
      assert_equal 0, QuestCompletion.count

      code_at(@user, SAT, 900, recorded_at: at(14, 9))
      assert_equal 1, Quests::Evaluate.call(@user).size
    end
  end

  test "a completion written by someone else a moment earlier is not written again and not reported as new" do
    with_feature(:quests) do
      finish_goal
      QuestCompletion.create!(user: @user, quest: @quest, completed_at: at(14, 9))
      assert_empty Quests::Evaluate.call(@user)
      assert_equal 1, QuestCompletion.count
    end
  end

  test "the unique index, not just the model, keeps one completion per person and quest" do
    row = QuestCompletion.create!(user: @user, quest: @quest, completed_at: at(14, 9))
    duplicate = QuestCompletion.new(user: @user, quest: @quest, completed_at: at(15, 9))
    assert_not duplicate.valid?
    assert_raises(ActiveRecord::RecordNotUnique) { QuestCompletion.transaction(requires_new: true) { duplicate.save!(validate: false) } }
    assert_equal [ row.id ], QuestCompletion.where(user_id: @user.id).pluck(:id)
  end

  test "flag off: nothing is read or written, even when the goal holds" do
    without_feature(:quests) do
      finish_goal
      assert_empty Quests::Evaluate.call(@user)
      assert_equal 0, QuestCompletion.count
      assert_equal({ users: 0, completions: 0, errors: 0 }, Quests::Evaluate.all)
    end
  end

  test "a quest whose week has not begun on the person's own calendar is not checked (hours can be credited for tomorrow)" do
    travel_to Time.utc(2026, 11, 12, 12)
    with_feature(:quests) do
      finish_goal # dated Friday and Saturday, while the person's today is Thursday
      assert_empty Quests::Evaluate.call(@user)
    end
  end

  test "a person far ahead of UTC starts the week on their own Friday" do
    nz = quest_user(time_zone: "Pacific/Auckland")
    travel_to Time.utc(2026, 11, 12, 12) # Friday 01:00 in Auckland
    with_feature(:quests) do
      code_at(nz, FRI, 900, recorded_at: Time.utc(2026, 11, 12, 11, 30))
      code_at(nz, SAT, 900, recorded_at: Time.utc(2026, 11, 12, 11, 40))
      assert_equal 1, Quests::Evaluate.call(nz).size
    end
  end

  test "a week that ended more than the grace days ago is no longer checked, within the grace it still is" do
    with_feature(:quests) do
      finish_goal
      travel_to Time.utc(2026, 11, 22, 12) # Sunday: three days after the Thursday the week ended
      assert_equal 1, Quests::Evaluate.call(@user).size
    end

    other = quest_user
    with_feature(:quests) do
      code_at(other, FRI, 900, recorded_at: at(13, 9))
      code_at(other, SAT, 900, recorded_at: at(14, 9))
      travel_to Time.utc(2026, 11, 23, 12)
      assert_empty Quests::Evaluate.call(other)
    end
  end

  test "a person who signed up after the week ended is skipped" do
    newcomer = quest_user(created_on: Date.new(2026, 11, 21))
    travel_to Time.utc(2026, 11, 21, 18)
    with_feature(:quests) do
      assert_empty Quests::Evaluate.call(newcomer)
    end
  end

  test "all evaluates every onboarded user, counts what it recorded and keeps going past one failure" do
    other = quest_user
    broken = quest_user
    unonboarded = User.create!(hca_uid: "ident!quest-#{SecureRandom.hex(6)}")
    with_feature(:quests) do
      finish_goal
      code_at(other, FRI, 900, recorded_at: at(13, 9))
      code_at(other, SAT, 900, recorded_at: at(14, 9))
      original = Quests::Evaluate.method(:call)
      failing = ->(user, **opts) { user.id == broken.id ? raise("boom") : original.call(user, **opts) }
      counts = with_replaced(Quests::Evaluate, :call, failing) { Quests::Evaluate.all }

      assert_equal 1, counts[:errors]
      assert_operator counts[:users], :>=, 2
      assert_equal 2, counts[:completions]
      assert_equal 0, QuestCompletion.where(user_id: unonboarded.id).count
    end
  end

  test "the rake task skips with the flag off and evaluates with it on" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("quests:evaluate")
    finish_goal

    without_feature(:quests) do
      out, = capture_io { Rake::Task["quests:evaluate"].execute }
      assert_match(/skipped/, out)
      assert_equal 0, QuestCompletion.count
    end
    with_feature(:quests) do
      out, = capture_io { Rake::Task["quests:evaluate"].execute }
      assert_match(/completions=1/, out)
      assert_equal 1, QuestCompletion.count
    end
  end
end
