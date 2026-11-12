# The crew bonus is its own ledger kind (`team_bonus`, a credit like the streak bonus), written once per ship under the key
# `team_bonus:ship:<id>`. The allowlists are written out literally so this migration keeps working if the model constants
# change later. The lists hold every kind present when this was written (including `quest_reward`); a later kind needs
# its own migration that rebuilds the constraints with the full list again.
class AddTeamBonusToCoinTransactions < ActiveRecord::Migration[8.1]
  def up
    replace_constraints(%w[ship_approval streak_bonus purchase refund adjustment quest_reward team_bonus], %w[ship_approval streak_bonus refund quest_reward team_bonus])
  end

  def down
    execute "DELETE FROM coin_transactions WHERE kind = 'team_bonus'"
    replace_constraints(%w[ship_approval streak_bonus purchase refund adjustment quest_reward], %w[ship_approval streak_bonus refund quest_reward])
  end

  private

  def replace_constraints(kinds, credit_kinds)
    remove_check_constraint :coin_transactions, name: "coin_transactions_kind_check"
    remove_check_constraint :coin_transactions, name: "coin_transactions_sign_check"
    add_check_constraint :coin_transactions, "kind IN (#{quote_list(kinds)})", name: "coin_transactions_kind_check"
    add_check_constraint :coin_transactions,
                         "(kind IN (#{quote_list(credit_kinds)}) AND amount > 0) OR (kind = 'purchase' AND amount < 0) OR kind = 'adjustment'",
                         name: "coin_transactions_sign_check"
  end

  def quote_list(values) = values.map { |value| "'#{value}'" }.join(", ")
end
