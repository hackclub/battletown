require "test_helper"
require_relative "../support/coins_helper"

class DailyResultTest < ActiveSupport::TestCase
  include CoinsHelper

  setup { @user = build_user }

  def row(overrides = {})
    { user_id: @user.id, local_date: Date.new(2026, 11, 1), raw_seconds: 900, quick_met: true, goal_met: false, freeze_used: false,
      streak_15: 1, goal_streak: 0, freeze_available: true, days_since_freeze: 0, bonus_bps: 500, created_at: Time.current }.merge(overrides)
  end

  def insert_sql(overrides = {})
    attrs = row(overrides)
    connection = ActiveRecord::Base.connection
    "INSERT INTO daily_results (#{attrs.keys.join(', ')}) VALUES (#{attrs.values.map { |v| connection.quote(v) }.join(', ')})"
  end

  def rejected_by_database(overrides)
    assert_raises(ActiveRecord::StatementInvalid) do
      ActiveRecord::Base.transaction(requires_new: true) { ActiveRecord::Base.connection.execute(insert_sql(overrides)) }
    end
  end

  test "a result is created once and is then immutable" do
    result = DailyResult.create!(row.except(:user_id).merge(user: @user))
    assert_raises(ActiveRecord::ReadOnlyRecord) { result.update!(raw_seconds: 1) }
    assert_raises(ActiveRecord::ReadOnlyRecord) { result.destroy }
    assert_equal 900, DailyResult.find(result.id).raw_seconds
    assert_equal Game::StreakCalculator::State.new(streak_15: 1, goal_streak: 0, freeze_available: true, days_since_freeze: 0), result.streak_state
  end

  test "one row per user and date, enforced by the database" do
    ActiveRecord::Base.connection.execute(insert_sql)
    rejected_by_database({})
    other = build_user
    assert_nothing_raised { ActiveRecord::Base.connection.execute(insert_sql(user_id: other.id)) }
  end

  test "raw SQL cannot insert out-of-range numbers" do
    rejected_by_database(raw_seconds: -1)
    rejected_by_database(raw_seconds: 86_401)
    rejected_by_database(streak_15: -1)
    rejected_by_database(goal_streak: -1)
    rejected_by_database(days_since_freeze: -1)
    rejected_by_database(bonus_bps: -1)
    rejected_by_database(bonus_bps: 10_001)
  end

  test "raw SQL cannot insert a bonus on a day that did not qualify or with no streak" do
    rejected_by_database(quick_met: false, bonus_bps: 500)
    rejected_by_database(streak_15: 0, bonus_bps: 500)
  end

  test "raw SQL cannot insert an impossible freeze day" do
    rejected_by_database(freeze_used: true, quick_met: true, bonus_bps: 0)
    rejected_by_database(freeze_used: true, quick_met: false, bonus_bps: 500)
    rejected_by_database(freeze_used: true, quick_met: false, bonus_bps: 0, streak_15: 0)
    rejected_by_database(freeze_used: true, quick_met: false, bonus_bps: 0, freeze_available: true)
    assert_nothing_raised do
      ActiveRecord::Base.connection.execute(insert_sql(freeze_used: true, quick_met: false, bonus_bps: 0, freeze_available: false, streak_15: 3))
    end
  end

  test "raw SQL cannot insert nulls or a missing user" do
    rejected_by_database(raw_seconds: nil)
    rejected_by_database(local_date: nil)
    rejected_by_database(user_id: User.maximum(:id) + 1000)
  end

  test "deleting a user deletes their daily results" do
    DailyResult.create!(row.except(:user_id).merge(user: @user))
    assert_difference -> { DailyResult.count }, -1 do
      User.where(id: @user.id).delete_all
    end
  end
end
