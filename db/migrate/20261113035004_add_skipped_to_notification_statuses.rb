# A `skipped` status: the dispatcher handled the row with an adapter that does not really deliver (the log adapter in
# development, the null adapter in tests), so nothing reached Slack. It is never recorded as `sent`.
# The allowlist is written out literally so this migration keeps working if the model constants change later.
class AddSkippedToNotificationStatuses < ActiveRecord::Migration[8.1]
  STATUSES = %w[pending sent failed cancelled skipped].freeze

  def up
    remove_check_constraint :notifications, name: "notifications_status_check"
    add_check_constraint :notifications, "status IN (#{STATUSES.map { |status| "'#{status}'" }.join(', ')})", name: "notifications_status_check"
  end

  def down
    execute "UPDATE notifications SET status = 'cancelled' WHERE status = 'skipped'"

    remove_check_constraint :notifications, name: "notifications_status_check"
    add_check_constraint :notifications, "status IN ('pending', 'sent', 'failed', 'cancelled')", name: "notifications_status_check"
  end
end
