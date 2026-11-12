# When the verification and eligibility columns were last copied from Hack Club Auth (every sign-in). The eligibility
# gate (flag `eligibility_gate`) treats an old copy as needing a re-check. Existing rows start from updated_at (or
# created_at): the last time we touched the row is the best guess for the last sign-in. New rows default to now.
class AddVerificationCheckedAtToUsers < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :verification_checked_at, :datetime
    backfill
    change_column_null :users, :verification_checked_at, false
    change_column_default :users, :verification_checked_at, from: nil, to: -> { "CURRENT_TIMESTAMP" }
  end

  def down
    remove_column :users, :verification_checked_at
  end

  def backfill
    execute "UPDATE users SET verification_checked_at = COALESCE(updated_at, created_at) WHERE verification_checked_at IS NULL"
  end
end
