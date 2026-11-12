module Coins
  # The only writer of the coin ledger. Every call runs in a transaction under `user.with_lock`, so two simultaneous
  # debits cannot both pass the balance check, and it is idempotent: repeating a call with the same idempotency key
  # returns the row already written (nothing is credited or debited twice).
  #
  # `credit` and `debit` both take a POSITIVE amount; a debit is stored negative. `reference` is an optional record
  # (for example a ship) or a [type, id] pair.
  module Ledger
    module_function

    def credit(user:, amount:, kind:, idempotency_key:, reference: nil, note: nil, created_by: nil)
      raise ArgumentError, "a credit kind is required, got #{kind.inspect}" unless kind.to_s.in?(CoinTransaction::CREDIT_KINDS + [ "adjustment" ])

      write(user, positive(amount), kind.to_s, idempotency_key, reference, note, created_by)
    end

    def debit(user:, amount:, kind:, idempotency_key:, reference: nil, note: nil, created_by: nil)
      raise ArgumentError, "a debit kind is required, got #{kind.inspect}" unless kind.to_s.in?(CoinTransaction::DEBIT_KINDS + [ "adjustment" ])

      write(user, -positive(amount), kind.to_s, idempotency_key, reference, note, created_by)
    end

    def positive(amount)
      raise ArgumentError, "amount must be an Integer" unless amount.is_a?(Integer)
      raise ArgumentError, "amount must be positive (a debit is stored negative for you)" unless amount.positive?

      amount
    end

    def write(user, signed_amount, kind, key, reference, note, created_by)
      type, id = reference_parts(reference)
      user.with_lock do
        existing = CoinTransaction.find_by(user_id: user.id, idempotency_key: key)
        next same_request!(existing, signed_amount, kind, key) if existing

        if signed_amount.negative? && Balance.total(user) + signed_amount < 0
          raise InsufficientBalance, "balance is #{Balance.total(user)}, cannot debit #{-signed_amount}"
        end

        CoinTransaction.create!(user: user, amount: signed_amount, kind: kind, idempotency_key: key, reference_type: type,
                                reference_id: id, note: note, created_by: created_by)
      end
    end

    def same_request!(existing, signed_amount, kind, key)
      return existing if existing.amount == signed_amount && existing.kind == kind

      raise IdempotencyConflict, "idempotency key #{key.inspect} was already used for a different transaction"
    end

    def reference_parts(reference)
      case reference
      when nil then [ nil, nil ]
      when Array then [ reference.first.to_s, Integer(reference.last) ]
      else [ reference.class.name, reference.id ]
      end
    end
  end
end
