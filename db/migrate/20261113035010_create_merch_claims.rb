# A person's claim on one boss week's merch-track item (behind the Flipper flag `merch_track`). One per person per
# week, no coins, no address (the team arranges delivery on Slack). Deleted with the person (the data-deletion API
# relies on the cascade) and with the boss.
class CreateMerchClaims < ActiveRecord::Migration[8.1]
  def change
    create_table :merch_claims do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :boss, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :item_key, null: false, limit: 60
      t.string :item_name, null: false, limit: 100
      t.string :status, null: false, default: "requested"
      t.datetime :claimed_at, null: false
      t.datetime :fulfilled_at
      t.datetime :cancelled_at
      t.timestamps
    end

    add_index :merch_claims, %i[user_id boss_id], unique: true
    add_index :merch_claims, %i[status claimed_at]
    add_index :merch_claims, :boss_id
    add_check_constraint :merch_claims, "status IN ('requested', 'fulfilled', 'cancelled')", name: "merch_claims_status_check"
    add_check_constraint :merch_claims, "(status = 'fulfilled') = (fulfilled_at IS NOT NULL)", name: "merch_claims_fulfilled_at_check"
    add_check_constraint :merch_claims, "(status = 'cancelled') = (cancelled_at IS NOT NULL)", name: "merch_claims_cancelled_at_check"
    add_check_constraint :merch_claims, "char_length(item_key) >= 1 AND char_length(item_name) >= 1", name: "merch_claims_item_check"
  end
end
