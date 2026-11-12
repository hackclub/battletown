# A user's voluntary link to their Hackatime account (OAuth). Minimal data on purpose: the Hackatime user id, the
# OAuth tokens (encrypted at rest by the model, so the columns hold ciphertext), the granted scopes and a few
# timestamps. No name, email or project data is stored. The row is deleted with the user (ON DELETE CASCADE, so
# the data-deletion API removes the tokens too). Allowlists and lengths are written out literally so this
# migration keeps working if the model changes later.
class CreateHackatimeConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :hackatime_connections do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :hackatime_uid, null: false
      t.text :access_token, null: false
      t.text :refresh_token
      t.string :scopes, null: false, default: ""
      t.datetime :expires_at
      t.datetime :connected_at, null: false
      t.datetime :last_synced_at
      t.string :last_error_code, limit: 40
      t.boolean :needs_reconnect, null: false, default: false
      t.timestamps
    end

    add_index :hackatime_connections, :hackatime_uid, unique: true

    add_check_constraint :hackatime_connections, "char_length(hackatime_uid) BETWEEN 1 AND 40",
                         name: "hackatime_connections_uid_length_check"
    add_check_constraint :hackatime_connections, "char_length(scopes) <= 100",
                         name: "hackatime_connections_scopes_length_check"
    # Ciphertext is JSON with a header, so it is longer than the token; this only stops runaway values.
    add_check_constraint :hackatime_connections, "char_length(access_token) <= 4000",
                         name: "hackatime_connections_access_token_length_check"
    add_check_constraint :hackatime_connections, "refresh_token IS NULL OR char_length(refresh_token) <= 4000",
                         name: "hackatime_connections_refresh_token_length_check"
    add_check_constraint :hackatime_connections, "last_error_code IS NULL OR last_error_code ~ '^[a-z0-9_]{1,40}$'",
                         name: "hackatime_connections_last_error_code_check"
  end
end
