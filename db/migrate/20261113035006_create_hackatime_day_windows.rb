# The UTC window each local date stood for the first time Hackatime time was fetched for it (docs/HACKATIME.md).
# Frozen once written, so changing time zone (or linking the same Hackatime account to a second Battletown account)
# never counts the same coded instant twice. `hackatime_uid` is the Hackatime account the window was fetched from.
# Deleted with the user (ON DELETE CASCADE, GDPR erasure).
class CreateHackatimeDayWindows < ActiveRecord::Migration[8.1]
  def change
    create_table :hackatime_day_windows do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.date :local_date, null: false
      t.datetime :starts_at, null: false
      t.datetime :ends_at, null: false
      t.string :hackatime_uid, null: false, limit: 40
      t.datetime :created_at, null: false
    end

    add_index :hackatime_day_windows, [ :user_id, :local_date ], unique: true
    add_index :hackatime_day_windows, [ :hackatime_uid, :ends_at ]
    add_check_constraint :hackatime_day_windows, "ends_at >= starts_at", name: "hackatime_day_windows_order_check"
    add_check_constraint :hackatime_day_windows, "char_length(hackatime_uid) BETWEEN 1 AND 40",
                         name: "hackatime_day_windows_uid_length_check"
  end
end
