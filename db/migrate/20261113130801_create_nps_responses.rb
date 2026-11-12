# One answer to the "how likely are you to recommend Battletown?" survey (feature flag `nps`).
#
# - One answer per person per prompt window (`prompt_window_date`: the person's local date the Slack message was queued
#   for), enforced by the unique index, so a link clicked twice or two tabs can never count twice.
# - `comment` is free text a teen typed: it can hold personal data, so it is short (300 characters, also checked by the
#   database), shown to staff only, and set to NULL after `nps.comment_retention_days` by `bin/rails nps:prune`. The score
#   is kept.
# - ON DELETE CASCADE: deleting a person (Privacy::Deleter) deletes their answers with them.
class CreateNpsResponses < ActiveRecord::Migration[8.1]
  def change
    create_table :nps_responses do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.integer :score, null: false
      t.string :comment, limit: 300
      t.datetime :answered_at, null: false
      t.date :prompt_window_date, null: false
      t.timestamps null: false
    end
    add_index :nps_responses, [ :user_id, :prompt_window_date ], unique: true
    add_index :nps_responses, :answered_at
    add_check_constraint :nps_responses, "score >= 0 AND score <= 10", name: "nps_responses_score_check"
    add_check_constraint :nps_responses, "comment IS NULL OR char_length(comment) <= 300", name: "nps_responses_comment_length_check"
  end
end
