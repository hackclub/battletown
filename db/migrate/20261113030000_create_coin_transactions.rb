# The coin ledger: append-only rows, credits positive and debits negative; a balance is the sum of a user's rows.
# Holds no free personal data: `note` is a short staff remark and `created_by` a short operator tag, never a name or
# an address. Rows are deleted with the user (ON DELETE CASCADE, GDPR erasure). The allowlists are written out
# literally so this migration keeps working if the model constants change later.
class CreateCoinTransactions < ActiveRecord::Migration[8.1]
  def change
    create_table :coin_transactions do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.integer :amount, null: false
      t.string :kind, null: false
      t.string :reference_type, limit: 60
      t.bigint :reference_id
      t.string :idempotency_key, null: false, limit: 120
      t.string :note, limit: 200
      t.string :created_by, limit: 40
      t.datetime :created_at, null: false
    end

    add_index :coin_transactions, [ :user_id, :idempotency_key ], unique: true
    add_index :coin_transactions, [ :user_id, :created_at ]
    add_index :coin_transactions, [ :reference_type, :reference_id ]

    add_check_constraint :coin_transactions, "amount <> 0", name: "coin_transactions_amount_check"
    add_check_constraint :coin_transactions,
                         "kind IN ('ship_approval', 'streak_bonus', 'purchase', 'refund', 'adjustment')",
                         name: "coin_transactions_kind_check"
    # Earnings and refunds are credits, purchases are debits, adjustments may go either way.
    add_check_constraint :coin_transactions,
                         "(kind IN ('ship_approval', 'streak_bonus', 'refund') AND amount > 0) OR " \
                         "(kind = 'purchase' AND amount < 0) OR kind = 'adjustment'",
                         name: "coin_transactions_sign_check"
    add_check_constraint :coin_transactions, "(reference_type IS NULL) = (reference_id IS NULL)",
                         name: "coin_transactions_reference_check"
    add_check_constraint :coin_transactions, "char_length(idempotency_key) BETWEEN 1 AND 120",
                         name: "coin_transactions_idempotency_key_check"
    add_check_constraint :coin_transactions, "note IS NULL OR char_length(note) <= 200",
                         name: "coin_transactions_note_check"
    add_check_constraint :coin_transactions, "created_by IS NULL OR created_by ~ '^[a-z0-9_:.-]{1,40}$'",
                         name: "coin_transactions_created_by_check"
  end
end
