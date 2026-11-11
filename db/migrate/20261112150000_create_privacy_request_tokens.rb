# One row per accepted data-deletion/export token (the JWT id), so a token can be used only once. Rows are
# inserted only after the token's signature and claims are verified, and deleted after 7 days (the tokens
# themselves expire after 5 minutes). It holds no personal data: no email, Slack id or identity id, and
# never the token.
class CreatePrivacyRequestTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :privacy_request_tokens do |t|
      t.string :jti, null: false
      t.string :request_id
      t.string :action
      t.boolean :dry_run
      t.datetime :created_at, null: false
    end

    add_index :privacy_request_tokens, :jti, unique: true
    add_index :privacy_request_tokens, :created_at

    add_check_constraint :privacy_request_tokens, "length(jti) BETWEEN 1 AND 255", name: "privacy_request_tokens_jti_check"
    add_check_constraint :privacy_request_tokens, "request_id IS NULL OR length(request_id) <= 255",
                         name: "privacy_request_tokens_request_id_check"
    add_check_constraint :privacy_request_tokens, "action IS NULL OR action IN ('delete', 'export')",
                         name: "privacy_request_tokens_action_check"
  end
end
