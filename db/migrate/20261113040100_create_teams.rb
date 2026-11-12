# Crews (the "team bonus", behind the Flipper flag `team`): a small group of friends who code on the same days.
#
# - `teams`: a crew. Optional short name (free text, shown only to the crew and to staff) and a random invite token that
#   is the only way in (no search, no directory). The token expires and can be regenerated, which revokes the old link.
#   A crew has no owner column on purpose: the "inviter" is the member who has been in longest, so deleting an
#   account never has to cascade into somebody else's crew.
# - `team_memberships`: one row per user (unique: one crew at a time). Both foreign keys cascade, so deleting a user
#   removes their membership, and deleting a crew removes its memberships. A crew left with no members is deleted by
#   Team.sweep_empty! (Privacy::Deleter calls it right after the users are deleted).
# - `team_cooldowns`: when a user last left a crew, so a leave cooldown can stop crew hopping. One row per user.
# - `team_payouts`: one row per approved ship that was looked at for the bonus (even when it paid nothing), so the
#   payout runs once per ship and never later with different data. `ship_id` is unique. `team_id` is nulled when a
#   crew is dissolved (the coins stay in the ledger).
class CreateTeams < ActiveRecord::Migration[8.1]
  def change
    create_table :teams do |t|
      t.string :name, limit: 40
      t.string :invite_token, null: false, limit: 32
      t.datetime :invite_expires_at, null: false
      t.timestamps
    end
    add_index :teams, :invite_token, unique: true
    add_check_constraint :teams, "name IS NULL OR char_length(name) BETWEEN 1 AND 40", name: "teams_name_check"
    add_check_constraint :teams, "char_length(invite_token) BETWEEN 16 AND 32", name: "teams_invite_token_check"

    create_table :team_memberships do |t|
      t.references :team, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.datetime :joined_at, null: false
      t.timestamps
    end

    create_table :team_cooldowns do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.datetime :left_at, null: false
    end

    create_table :team_payouts do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.references :ship, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.references :team, foreign_key: { on_delete: :nullify }
      t.integer :coins, null: false, default: 0
      t.integer :matched_days, null: false, default: 0
      t.datetime :created_at, null: false
    end
    add_check_constraint :team_payouts, "coins >= 0 AND matched_days >= 0", name: "team_payouts_amounts_check"
  end
end
