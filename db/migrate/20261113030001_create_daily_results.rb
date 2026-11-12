# One immutable row per user per settled local day (see Game::Settle). Besides the day's outcome it stores the streak
# state AFTER the day (freeze_available, days_since_freeze) so the next day can be settled from the previous row alone.
# Holds only numbers and flags; deleted with the user (ON DELETE CASCADE, GDPR erasure).
class CreateDailyResults < ActiveRecord::Migration[8.1]
  def change
    create_table :daily_results do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.date :local_date, null: false
      t.integer :raw_seconds, null: false
      t.boolean :quick_met, null: false
      t.boolean :goal_met, null: false
      t.boolean :freeze_used, null: false, default: false
      t.integer :streak_15, null: false
      t.integer :goal_streak, null: false
      t.boolean :freeze_available, null: false
      t.integer :days_since_freeze, null: false, default: 0
      t.integer :bonus_bps, null: false, default: 0
      t.datetime :created_at, null: false
    end

    add_index :daily_results, [ :user_id, :local_date ], unique: true

    add_check_constraint :daily_results, "raw_seconds >= 0 AND raw_seconds <= 86400", name: "daily_results_raw_seconds_check"
    add_check_constraint :daily_results, "streak_15 >= 0 AND goal_streak >= 0 AND days_since_freeze >= 0",
                         name: "daily_results_counters_check"
    add_check_constraint :daily_results, "bonus_bps >= 0 AND bonus_bps <= 10000", name: "daily_results_bonus_bps_check"
    add_check_constraint :daily_results, "NOT (bonus_bps > 0 AND NOT quick_met)", name: "daily_results_bonus_needs_quick_check"
    add_check_constraint :daily_results, "NOT (bonus_bps > 0 AND streak_15 = 0)", name: "daily_results_bonus_needs_streak_check"
    add_check_constraint :daily_results, "NOT (freeze_used AND quick_met)", name: "daily_results_freeze_not_on_met_day_check"
    add_check_constraint :daily_results, "NOT (freeze_used AND bonus_bps > 0)", name: "daily_results_freeze_no_bonus_check"
    add_check_constraint :daily_results, "NOT (freeze_used AND streak_15 = 0)", name: "daily_results_freeze_needs_streak_check"
    add_check_constraint :daily_results, "NOT (freeze_used AND freeze_available)", name: "daily_results_freeze_spent_check"
  end
end
