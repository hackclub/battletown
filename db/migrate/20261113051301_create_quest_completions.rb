# One row per user per quest, written once when the goal first held. The reward is paid later, with the person's next
# approved ship: `coin_transaction_id` points at that ledger row (nil while the reward is still waiting). Deleted with
# the user and with the quest or the ledger row by the database (ON DELETE CASCADE, GDPR erasure).
class CreateQuestCompletions < ActiveRecord::Migration[8.1]
  def change
    create_table :quest_completions do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :quest, null: false, foreign_key: { on_delete: :cascade }
      t.datetime :completed_at, null: false
      t.references :coin_transaction, null: true, foreign_key: { on_delete: :cascade }
      t.timestamps
    end

    add_index :quest_completions, [ :user_id, :quest_id ], unique: true
    add_index :quest_completions, :user_id, where: "coin_transaction_id IS NULL", name: "index_quest_completions_pending_by_user"
  end
end
