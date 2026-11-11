class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :hca_uid, null: false
      t.string :email
      t.string :display_name
      t.string :slack_id
      t.string :verification_status, null: false, default: "needs_submission"
      t.boolean :ysws_eligible, null: false, default: false
      t.string :referral_source
      t.string :prize_key
      t.string :project_kind
      t.text :project_idea
      t.integer :coding_days, null: false, default: 0
      t.string :coding_time
      t.string :time_zone
      t.integer :onboarding_step, null: false, default: 0
      t.datetime :onboarded_at

      t.timestamps
    end
    add_index :users, :hca_uid, unique: true
    add_index :users, :slack_id
  end
end
