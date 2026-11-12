module Shop
  # Old doorway to Orders::Cancel, kept so callers written before the order lifecycle (tests, scripts) keep working. Same rules as
  # Orders::Cancel: the owner (only while requested) or an admin, one refund, repeating changes nothing. An admin who gives no
  # reason code is recorded with "other". Returns the order. New code calls Orders::Cancel (it returns a result with the event).
  class Cancel
    def self.call(order:, by:, reason_code: nil)
      as = by&.admin? && by.id != order.user_id ? :staff : :buyer
      reason_code ||= "other" if as == :staff
      Orders::Cancel.call(order: order, by: by, as: as, reason_code: reason_code).order
    end
  end
end
