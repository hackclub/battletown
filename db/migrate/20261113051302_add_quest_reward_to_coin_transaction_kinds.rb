# A new ledger kind, `quest_reward` (a credit), paid by Quests::Payout with the user's next approved ship. Rebuilds the
# kind and sign constraints; the lists are written out literally so this migration keeps working if the model changes.
class AddQuestRewardToCoinTransactionKinds < ActiveRecord::Migration[8.1]
  KINDS = %w[ship_approval streak_bonus purchase refund adjustment quest_reward].freeze
  CREDITS = %w[ship_approval streak_bonus refund quest_reward].freeze

  def up
    rebuild(KINDS, CREDITS)
  end

  def down
    execute "DELETE FROM coin_transactions WHERE kind = 'quest_reward'"
    rebuild(KINDS - %w[quest_reward], CREDITS - %w[quest_reward])
  end

  private

  def rebuild(kinds, credits)
    remove_check_constraint :coin_transactions, name: "coin_transactions_kind_check"
    remove_check_constraint :coin_transactions, name: "coin_transactions_sign_check"
    add_check_constraint :coin_transactions, "kind IN (#{list(kinds)})", name: "coin_transactions_kind_check"
    add_check_constraint :coin_transactions,
                         "(kind IN (#{list(credits)}) AND amount > 0) OR (kind = 'purchase' AND amount < 0) OR kind = 'adjustment'",
                         name: "coin_transactions_sign_check"
  end

  def list(values) = values.map { |value| "'#{value}'" }.join(", ")
end
