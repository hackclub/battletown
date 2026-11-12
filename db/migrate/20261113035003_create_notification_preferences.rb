# Which Slack messages a person wants. A row only exists once someone has changed a switch; no row means the default
# (every kind on). Deleted with the user (ON DELETE CASCADE, GDPR erasure). The kind allowlist is written out
# literally so this migration keeps working if the model constants change later.
class CreateNotificationPreferences < ActiveRecord::Migration[8.1]
  KINDS = %w[daily_reminder link_question ship_reminder ship_mvp ship_approved ship_rejected].freeze

  def change
    create_table :notification_preferences do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :kind, null: false
      t.boolean :enabled, null: false, default: true
      t.timestamps
    end

    add_index :notification_preferences, [ :user_id, :kind ], unique: true
    add_check_constraint :notification_preferences, "kind IN (#{KINDS.map { |kind| "'#{kind}'" }.join(', ')})",
                         name: "notification_preferences_kind_check"
  end
end
