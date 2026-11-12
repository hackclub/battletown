# A user finished a quest: written once, the first time Quests::Evaluate sees the goal has held, with the moment it
# first held (`completed_at`, from the ledger). The reward waits (`coin_transaction_id` is nil) until Quests::Payout
# pays it with the user's next approved ship and records the ledger row here. One per user and quest (unique index).
# Deleted with the user, the quest or the ledger row by the database (ON DELETE CASCADE), not by the model.
class QuestCompletion < ApplicationRecord
  belongs_to :user
  belongs_to :quest
  belongs_to :coin_transaction, optional: true

  validates :completed_at, presence: true
  validates :quest_id, uniqueness: { scope: :user_id }

  scope :pending, -> { where(coin_transaction_id: nil) }
  scope :paid, -> { where.not(coin_transaction_id: nil) }

  def paid? = coin_transaction_id.present?
end
