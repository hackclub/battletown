module AdminUsers
  # Add or take off coins as a new `adjustment` entry in the coin ledger (Coins::Ledger, the only writer). The earlier entries
  # are never edited. Bounded to config `admin_users.max_adjust_coins` a time, and a balance can never go below zero.
  class CoinAdjustment < Adjustment
    attribute :coins, :string

    validate :coins_are_usable
    validate :balance_stays_positive

    def whole_coins = coins.to_s.match?(/\A\d{1,7}\z/) ? coins.to_i : nil

    def amount = (whole_coins || 0) * sign

    def balance_before = @balance_before ||= Coins::Balance.total(user)

    def balance_after = balance_before + amount

    private

    def existing_record = CoinTransaction.find_by(user_id: user.id, idempotency_key: idempotency_key)

    def write!
      options = { user: user, amount: whole_coins, kind: "adjustment", idempotency_key: idempotency_key, note: reason, created_by: created_by }
      transaction = add? ? Coins::Ledger.credit(**options) : Coins::Ledger.debit(**options)
      AdminAudit.record!(actor: staff, action: "coins_adjusted", subject: user,
                         metadata: { amount: amount, reason: reason, transaction_id: transaction.id, balance_after: Coins::Balance.total(user) })
      transaction
    rescue Coins::InsufficientBalance
      errors.add(:coins, "would take the balance below zero")
      raise Invalid, self
    end

    def coins_are_usable
      max = Config.current.max_adjust_coins
      return if whole_coins&.between?(1, max)

      errors.add(:coins, "must be a whole number from 1 to #{ActiveSupport::NumberHelper.number_to_delimited(max)}")
    end

    def balance_stays_positive
      return if whole_coins.nil? || !DIRECTIONS.include?(direction)

      errors.add(:coins, "would take the balance below zero (it is #{balance_before} now)") if balance_after.negative?
    end
  end
end
