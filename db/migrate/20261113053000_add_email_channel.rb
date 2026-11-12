# Email as a second notification channel (behind the Flipper flag `email`).
#
# - notifications.channel may now be `email` (the allowlist is written out literally, so this migration keeps working
#   if the model constants change later). A row still holds no address and no text.
# - notification_preferences gets a channel (slack_dm by default, so every existing row keeps meaning "Slack"): one
#   switch per person, kind AND channel.
# - users gets the two email-only settings: `email_opted_out_at` (the "no email at all" switch, also what the one-click
#   unsubscribe sets) and `email_unsubscribe_nonce`, the per-person secret signed into every unsubscribe link. It is
#   rotated when someone turns email back on, which revokes every link already sent. The default gives existing rows
#   (and new ones) a random value without any application code.
class AddEmailChannel < ActiveRecord::Migration[8.1]
  CHANNELS = %w[slack_dm email].freeze

  def up
    remove_check_constraint :notifications, name: "notifications_channel_check"
    add_check_constraint :notifications, "channel IN (#{quoted(CHANNELS)})", name: "notifications_channel_check"

    add_column :notification_preferences, :channel, :string, null: false, default: "slack_dm"
    add_check_constraint :notification_preferences, "channel IN (#{quoted(CHANNELS)})", name: "notification_preferences_channel_check"
    remove_index :notification_preferences, name: "index_notification_preferences_on_user_id_and_kind"
    add_index :notification_preferences, %i[user_id kind channel], unique: true, name: "index_notification_preferences_on_user_kind_channel"

    add_column :users, :email_opted_out_at, :datetime
    add_column :users, :email_unsubscribe_nonce, :string, null: false, default: -> { "gen_random_uuid()::text" }
  end

  def down
    remove_column :users, :email_unsubscribe_nonce
    remove_column :users, :email_opted_out_at

    execute "DELETE FROM notification_preferences WHERE channel <> 'slack_dm'"
    remove_index :notification_preferences, name: "index_notification_preferences_on_user_kind_channel"
    remove_check_constraint :notification_preferences, name: "notification_preferences_channel_check"
    remove_column :notification_preferences, :channel
    add_index :notification_preferences, %i[user_id kind], unique: true, name: "index_notification_preferences_on_user_id_and_kind"

    execute "DELETE FROM notifications WHERE channel <> 'slack_dm'"
    remove_check_constraint :notifications, name: "notifications_channel_check"
    add_check_constraint :notifications, "channel = 'slack_dm'", name: "notifications_channel_check"
  end

  private

  def quoted(values) = values.map { |value| "'#{value}'" }.join(", ")
end
