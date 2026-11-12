# The returning-user bonus (feature flag `returning`, see Game::ReturningBoost). One row per welcome-back window: the
# first counted day back after an idle stretch and the days after it (`ends_on` inclusive). A settled day inside a
# window has its streak bonus floored when it is settled; the streak counter itself is never touched. Dates are the
# user's own local dates. Written once per idle period (unique per user and start date). It holds no personal data
# beyond the user it belongs to, and is deleted with the user (ON DELETE CASCADE, GDPR erasure).
class CreateWelcomeBackWindows < ActiveRecord::Migration[8.1]
  def change
    create_table :welcome_back_windows do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.date :starts_on, null: false
      t.date :ends_on, null: false
      t.integer :idle_days, null: false
      t.timestamps
    end

    add_index :welcome_back_windows, [ :user_id, :starts_on ], unique: true
    add_index :welcome_back_windows, :starts_on
    add_check_constraint :welcome_back_windows, "ends_on >= starts_on", name: "welcome_back_windows_dates_check"
    add_check_constraint :welcome_back_windows, "idle_days >= 1", name: "welcome_back_windows_idle_days_check"
  end
end
