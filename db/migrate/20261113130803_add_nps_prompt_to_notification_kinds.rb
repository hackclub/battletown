# The NPS survey message (`nps_prompt`, behind the `nps` flag), about a prompt window: `subject_id` is the window's local
# date as a number (20261113). The allowlists (notifications.kind and notification_preferences.kind) are written out
# literally so this migration keeps working if the model constant changes later; they are the full list on the
# platform branch when this was written plus the new kind.
class AddNpsPromptToNotificationKinds < ActiveRecord::Migration[8.1]
  OLD_KINDS = %w[daily_reminder link_question ship_reminder ship_mvp ship_approved ship_rejected returning_nudge].freeze
  KINDS = (OLD_KINDS + %w[nps_prompt]).freeze
  CHECKS = { notifications: "notifications_kind_check", notification_preferences: "notification_preferences_kind_check" }.freeze

  def up
    replace_checks(KINDS)
  end

  def down
    execute "DELETE FROM notifications WHERE kind = 'nps_prompt'"
    execute "DELETE FROM notification_preferences WHERE kind = 'nps_prompt'"
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
