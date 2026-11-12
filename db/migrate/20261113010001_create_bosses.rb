# The weekly boss: one row per week (Friday to Thursday), with its health in seconds of coded time. Damage is never
# stored: it is derived from the hours ledger over [starts_on, ends_on] (Bosses::Damage), so a late or corrected
# entry just changes the sum. `defeated_at` is set once (Bosses::CheckDefeat) and never cleared. A boss is not about a
# person, so there is no user reference. The art allowlist lives in the model (Boss::ART_KEYS) so a new illustration
# does not need a migration; the database only checks its shape.
class CreateBosses < ActiveRecord::Migration[8.1]
  def change
    create_table :bosses do |t|
      t.string :name, null: false, limit: 60
      t.string :art_key, null: false, limit: 40
      t.date :starts_on, null: false
      t.date :ends_on, null: false
      t.integer :hp_seconds, null: false
      t.datetime :defeated_at
      t.timestamps
    end

    add_index :bosses, :starts_on, unique: true

    add_check_constraint :bosses, "char_length(btrim(name)) BETWEEN 1 AND 60", name: "bosses_name_check"
    add_check_constraint :bosses, "art_key ~ '^[a-z0-9_-]{1,40}$'", name: "bosses_art_key_check"
    add_check_constraint :bosses, "ends_on >= starts_on", name: "bosses_dates_check"
    add_check_constraint :bosses, "hp_seconds BETWEEN 1 AND 360000000", name: "bosses_hp_seconds_check"

    # Date ranges (inclusive) of two bosses may never overlap. Plain dates need no btree_gist extension.
    add_exclusion_constraint :bosses, "daterange(starts_on, ends_on, '[]') WITH &&", using: :gist, name: "bosses_no_overlap"
  end
end
