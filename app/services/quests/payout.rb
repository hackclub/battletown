module Quests
  # Pays the quest rewards that are waiting. A completed quest is not paid when it is completed: it is paid together
  # with the user's NEXT APPROVED SHIP, the earliest one approved at or after the moment the quest was completed. So
  # coins still come only from work a person has reviewed, and a quest nobody ships behind pays nothing.
  #
  # One ledger credit per (quest, user), kind `quest_reward`, idempotency key `quest:<quest id>:user:<user id>`, the
  # approved ship as its reference. The whole thing runs under the user's row lock (the ledger takes the same lock), so
  # two events at once, a repeated event or a rake run pay once; the completion row records which ledger row paid it.
  # It never touches Coins::ApproveShip: the ship's own coins are already written, the reward is a second, separate row.
  #
  # Called by Quests::Evaluate (so the dashboard load, the rake task and the ship-approved subscriber all reach it).
  module Payout
    module_function

    # Returns the QuestCompletions paid by this call.
    def call(user, now: Time.current)
      return [] unless Features.enabled?(:quests)
      return [] unless QuestCompletion.pending.where(user_id: user.id).exists?

      user.with_lock do
        QuestCompletion.pending.where(user_id: user.id).includes(:quest).order(:completed_at, :id).filter_map do |completion|
          ship = next_approved_ship(user, completion)
          pay(user, completion, ship) if ship
        end
      end
    end

    # The earliest ship the user had approved at or after the quest was completed.
    def next_approved_ship(user, completion)
      Ship.where(user_id: user.id, status: "approved", reviewed_at: completion.completed_at..).order(:reviewed_at, :id).first
    end

    def pay(user, completion, ship)
      quest = completion.quest
      entry = Coins::Ledger.credit(user: user, amount: quest.reward_coins, kind: "quest_reward", reference: ship,
                                   idempotency_key: "quest:#{quest.id}:user:#{user.id}", note: "Weekly quest", created_by: "quests")
      completion.update!(coin_transaction_id: entry.id)
      completion
    end
    private_class_method :next_approved_ship, :pay
  end
end
