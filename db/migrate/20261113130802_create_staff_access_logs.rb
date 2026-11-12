# A minimal record of staff looking at something sensitive (today: who wrote an NPS comment). It stores who did it
# (`actor_id`, nulled when that staff member is deleted), what they did and to which row, and when: never the content
# they saw, and never the identity of the person it was about (the subject row reaches them through its own cascading key).
class CreateStaffAccessLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :staff_access_logs do |t|
      t.references :actor, foreign_key: { to_table: :users, on_delete: :nullify }, index: true
      t.string :action, null: false, limit: 60
      t.string :subject_type, null: false, limit: 60
      t.bigint :subject_id, null: false
      t.datetime :created_at, null: false
    end
    add_index :staff_access_logs, [ :subject_type, :subject_id ]
    add_index :staff_access_logs, :created_at
  end
end
