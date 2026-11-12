# Order status messages (order_shipped, order_fulfilled, order_cancelled, order_refunded), each about one order (`subject_id`
# is the order id). The allowlists (notifications.kind and notification_preferences.kind) are written out literally so this
# migration keeps working if the model constant changes later; they are the full list on the platform branch when this was
# written plus the new kinds.
class AddOrderKindsToNotifications < ActiveRecord::Migration[8.1]
  OLD_KINDS = %w[daily_reminder link_question ship_reminder ship_mvp ship_approved ship_rejected returning_nudge nps_prompt].freeze
  NEW_KINDS = %w[order_shipped order_fulfilled order_cancelled order_refunded].freeze
  KINDS = (OLD_KINDS + NEW_KINDS).freeze
  CHECKS = { notifications: "notifications_kind_check", notification_preferences: "notification_preferences_kind_check" }.freeze

  def up
    replace_checks(KINDS)
  end

  def down
    CHECKS.each_key { |table| execute "DELETE FROM #{table} WHERE kind IN (#{NEW_KINDS.map { |kind| "'#{kind}'" }.join(', ')})" }
    replace_checks(OLD_KINDS)
  end

  private

  def replace_checks(kinds)
    CHECKS.each do |table, name|
      remove_check_constraint table, name: name
      add_check_constraint table, "kind IN (#{kinds.map { |kind| "'#{kind}'" }.join(', ')})", name: name
    end
  end
end
