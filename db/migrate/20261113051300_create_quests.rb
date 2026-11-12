# Quests: one admin-set goal per boss week, picked from a fixed menu the code can check by itself (Quests::Goals).
# A quest holds no personal data and has no user reference. The week is the boss week (Friday to Thursday) and is
# unique; the goal allowlist is written out literally so this migration keeps working if the code menu changes later.
class CreateQuests < ActiveRecord::Migration[8.1]
  def change
    create_table :quests do |t|
      t.date :starts_on, null: false
      t.date :ends_on, null: false
      t.string :goal_key, null: false, limit: 40
      t.jsonb :goal_params, null: false, default: {}
      t.integer :reward_coins, null: false
      t.timestamps
    end

    add_index :quests, :starts_on, unique: true
    add_check_constraint :quests, "ends_on >= starts_on", name: "quests_dates_check"
    add_check_constraint :quests, "goal_key IN ('code_days', 'streak_days', 'ship_project', 'link_hackatime', 'add_project')",
                         name: "quests_goal_key_check"
    add_check_constraint :quests, "jsonb_typeof(goal_params) = 'object'", name: "quests_goal_params_check"
    add_check_constraint :quests, "reward_coins >= 1 AND reward_coins <= 1000", name: "quests_reward_coins_check"
  end
end
