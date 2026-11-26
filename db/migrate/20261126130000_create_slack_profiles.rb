# What Battletown keeps from a player's Slack profile (every player has a profile; there is no opt-in, see 20261126160000):
# the display name and a RE-ENCODED, small WebP copy of the picture (SlackProfiles::Avatar; the original and Slack's URL are never
# kept), plus the bookkeeping of the lazy, at-most-once-a-day refresh (SlackProfiles::Refresh). One row per user, made the first time
# a fetch is due. It goes with the person (ON DELETE CASCADE, so Privacy::Deleter covers it), and turning the choice off wipes the name
# and picture. Only the Slack display name is kept, never the Slack real name. `use_name` and `use_picture` are the "Use my Slack name and picture" choice (both on by default).
class CreateSlackProfiles < ActiveRecord::Migration[8.1]
  STATUSES = %w[pending ok no_picture missing_scope invalid_auth not_found no_token ratelimited error].freeze

  def change
    create_table :slack_profiles do |t|
      t.references :user, null: false, index: { unique: true }, foreign_key: { on_delete: :cascade }
      t.boolean :use_name, null: false, default: true
      t.boolean :use_picture, null: false, default: true
      t.string :display_name, limit: 30
      t.binary :picture
      t.string :picture_sha256, limit: 64
      t.integer :picture_bytes
      t.string :status, null: false, default: "pending", limit: 20
      t.integer :failure_count, null: false, default: 0
      t.datetime :fetched_at
      t.datetime :next_attempt_at
      t.timestamps
    end

    add_check_constraint :slack_profiles, "status IN (#{STATUSES.map { |status| "'#{status}'" }.join(', ')})", name: "slack_profiles_status_check"
    add_check_constraint :slack_profiles, "picture_bytes IS NULL OR picture_bytes BETWEEN 1 AND 100000", name: "slack_profiles_picture_bytes_check"
    add_check_constraint :slack_profiles, "(picture IS NULL) = (picture_sha256 IS NULL)", name: "slack_profiles_picture_pair_check"
  end
end
