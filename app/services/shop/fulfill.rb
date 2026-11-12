module Shop
  # Old doorway to Orders::Fulfil, kept so callers written before the order lifecycle keep working: admin only, idempotent, keeps
  # the first fulfilled_at, now also from `shipped`. Returns the order. New code calls Orders::Fulfil.
  class Fulfill
    def self.call(order:, by:) = Orders::Fulfil.call(order: order, by: by, as: :staff).order
  end
end
