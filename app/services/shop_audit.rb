# Records an admin's change to the shop catalogue in the staff audit log, if there is one. A thin adapter, so the shop
# admin does not depend on how the log is built: when `AdminAudit` exists (the staff audit log), every call goes to
# `AdminAudit.record!(actor:, action:, subject:, metadata:)`; when it does not, nothing is recorded and nothing fails.
#
# Metadata is about the CATALOGUE only (field names, coin prices, a direction): never anything about a person.
module ShopAudit
  ACTIONS = %w[shop_item_created shop_item_updated shop_item_archived shop_item_restored shop_item_reordered].freeze

  module_function

  def record(actor:, action:, subject:, metadata: {})
    raise ArgumentError, "unknown shop audit action: #{action}" unless ACTIONS.include?(action)
    return unless defined?(AdminAudit)

    AdminAudit.record!(actor: actor, action: action, subject: subject, metadata: metadata)
  end
end
