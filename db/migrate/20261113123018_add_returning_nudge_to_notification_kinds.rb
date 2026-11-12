# The returning-user nudge (`returning_nudge`, one Slack DM per idle period) joins the allowed notification kinds, in
# the outbox and in the per-person switches. The allowlists are written out literally so this migration keeps working
# if the model constants change later.
class AddReturningNudgeToNotificationKinds < ActiveRecord::Migration[8.1]
  OLD_KINDS = %w[daily_reminder link_question ship_reminder ship_mvp ship_approved ship_rejected].freeze
  NEW_KINDS = (OLD_KINDS + %w[returning_nudge]).freeze

  def up
    replace_kind_check(:notifications, "notifications_kind_check", NEW_KINDS)
    replace_kind_check(:notification_preferences, "notification_preferences_kind_check", NEW_KINDS)
  end

  def down
    execute "DELETE FROM notifications WHERE kind = 'returning_nudge'"
    execute "DELETE FROM notification_preferences WHERE kind = 'returning_nudge'"
    replace_kind_check(:notifications, "notifications_kind_check", OLD_KINDS)
    replace_kind_check(:notification_preferences, "notification_preferences_kind_check", OLD_KINDS)
  end

  private

  def replace_kind_check(table, name, kinds)
    remove_check_constraint table, name: name
    add_check_constraint table, "kind IN (#{kinds.map { |kind| "'#{kind}'" }.join(', ')})", name: name
  end
end
