# A short private note staff leave about a person (Admin::UserNotesController). Append-only: no edits, no deletes from the app.
# Deleted with the person (ON DELETE CASCADE, so the data-deletion API removes them too); the author is only an id and is
# nulled if that staff member is deleted. Staff-written text, shown to staff only, never to the person.
class CreateUserNotes < ActiveRecord::Migration[8.1]
  def change
    create_table :user_notes do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :author, foreign_key: { to_table: :users, on_delete: :nullify }, index: true
      t.string :body, null: false, limit: 500
      t.datetime :created_at, null: false
    end
    add_index :user_notes, [ :user_id, :created_at ]
    add_check_constraint :user_notes, "char_length(btrim(body)) >= 1", name: "user_notes_body_present_check"
  end
end
