# Staff project review (docs/CONTRACT.md, "Project review"): an append-only history of what staff decided about a project.
# The newest row is the current state; projects.review_status / reviewed_at copy it (next migration) so the queue can filter.
# A review never touches coding, hours, coins or shipping. Rows go with the project (and so with the teen) by the database;
# `reviewer_id` is a staff user and is nulled when that person is deleted, so the history stays and the person is forgotten.
class CreateProjectReviews < ActiveRecord::Migration[8.1]
  def change
    create_table :project_reviews do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :reviewer, foreign_key: { to_table: :users, on_delete: :nullify }, index: true
      t.string :status, null: false
      t.text :note
      t.datetime :created_at, null: false
    end
    add_index :project_reviews, [ :project_id, :created_at ], order: { created_at: :desc }, name: "index_project_reviews_on_project_id_and_created_at"
    add_check_constraint :project_reviews, "status IN ('ok', 'flagged')", name: "project_reviews_status_check"
    add_check_constraint :project_reviews, "note IS NULL OR char_length(note) <= 500", name: "project_reviews_note_length_check"
    add_check_constraint :project_reviews, "status <> 'flagged' OR (note IS NOT NULL AND note ~ '[^[:space:]]')", name: "project_reviews_flag_needs_note_check"
  end
end
