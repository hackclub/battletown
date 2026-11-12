# Shop orders: a request for one item, paid in coins (the debit lives in the coin ledger, referencing the order).
# `coins` is the price at order time (a snapshot: later price changes never touch an order). No address or any other
# personal data is stored here; delivery is arranged by the team over Slack. Rows are deleted with the user
# (ON DELETE CASCADE, GDPR erasure). prize_key is not constrained in the database because the catalogue
# (config/prizes.yml) is placeholder data and changes; the model validates it against Prize.keys. The other
# allowlists are written out literally so this migration keeps working if the model constants change later.
class CreateOrders < ActiveRecord::Migration[8.1]
  def change
    create_table :orders do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :prize_key, null: false, limit: 60
      t.string :prize_name, null: false, limit: 100
      t.integer :coins, null: false
      t.string :kind, null: false
      t.string :status, null: false, default: "requested"
      t.string :idempotency_key, null: false, limit: 100
      t.datetime :fulfilled_at
      t.datetime :cancelled_at
      t.timestamps
    end

    add_index :orders, [ :user_id, :idempotency_key ], unique: true
    add_index :orders, [ :user_id, :created_at ]
    add_index :orders, [ :status, :created_at ]
    # A person gets one free signup sticker, ever (even if that order is later cancelled).
    add_index :orders, :user_id, unique: true, where: "kind = 'signup_sticker'", name: "index_orders_one_signup_sticker_per_user"

    add_check_constraint :orders, "coins >= 0", name: "orders_coins_check"
    add_check_constraint :orders, "kind IN ('purchase', 'signup_sticker')", name: "orders_kind_check"
    add_check_constraint :orders, "status IN ('requested', 'fulfilled', 'cancelled')", name: "orders_status_check"
    # The free sticker costs nothing; a purchase always costs something.
    add_check_constraint :orders, "(kind = 'signup_sticker' AND coins = 0) OR (kind = 'purchase' AND coins > 0)",
                         name: "orders_kind_coins_check"
    # The timestamps say exactly what the status says.
    add_check_constraint :orders, "(status = 'fulfilled') = (fulfilled_at IS NOT NULL)", name: "orders_fulfilled_at_check"
    add_check_constraint :orders, "(status = 'cancelled') = (cancelled_at IS NOT NULL)", name: "orders_cancelled_at_check"
    add_check_constraint :orders, "char_length(idempotency_key) BETWEEN 1 AND 100", name: "orders_idempotency_key_check"
    add_check_constraint :orders, "char_length(prize_key) >= 1 AND char_length(prize_name) >= 1", name: "orders_prize_check"
  end
end
