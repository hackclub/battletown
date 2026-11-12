# Plinko, the daily toy (docs/CONTRACT.md, "Plinko"). It never touches coins.
#
# plinko_drops: one row per ball dropped. The server picks the slot from `seed` (Plinko::Board.walk), so the path
# can be replayed; `local_date` is the player's local date when the ball was dropped (frozen, like the hours ledger),
# and `idempotency_key` makes a repeated request for the same drop a no-op. Balls themselves are never stored: they
# are derived from the hours ledger minus these rows (Plinko::Balls).
#
# plinko_players: the opt-in leaderboard setting and a generated nickname (never derived from a real name). The row
# is made the first time someone opens the Plinko page while the flag is on.
#
# Both tables are deleted with the user (ON DELETE CASCADE, privacy API).
class CreatePlinko < ActiveRecord::Migration[8.1]
  def change
    create_table :plinko_drops do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.datetime :dropped_at, null: false
      t.date :local_date, null: false
      t.integer :slot, null: false
      t.integer :points, null: false
      t.bigint :seed, null: false
      t.string :idempotency_key, null: false, limit: 64
    end

    add_index :plinko_drops, [ :user_id, :dropped_at ]
    add_index :plinko_drops, [ :user_id, :idempotency_key ], unique: true
    add_index :plinko_drops, :local_date
    add_check_constraint :plinko_drops, "slot >= 0", name: "plinko_drops_slot_check"
    add_check_constraint :plinko_drops, "points >= 0", name: "plinko_drops_points_check"
    add_check_constraint :plinko_drops, "char_length(idempotency_key) BETWEEN 8 AND 64", name: "plinko_drops_key_length_check"

    create_table :plinko_players do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :nickname, null: false, limit: 40
      t.boolean :leaderboard_opt_in, null: false, default: false
      t.timestamps
    end

    add_index :plinko_players, "lower(nickname)", unique: true, name: "index_plinko_players_on_lower_nickname"
    add_index :plinko_players, :leaderboard_opt_in, where: "leaderboard_opt_in", name: "index_plinko_players_on_opt_in"
  end
end
