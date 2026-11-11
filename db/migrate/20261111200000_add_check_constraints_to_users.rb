# Database-level backstop for the allowlists in User (the model validations stay the primary check).
# prize_key is deliberately not constrained here: prizes are placeholder data in config/prizes.yml and change.
# Keep PROJECT_KINDS and the verification statuses in sync with app/models/user.rb; they are written out
# literally so this migration keeps working even if the model constants change later.
class AddCheckConstraintsToUsers < ActiveRecord::Migration[8.1]
  CONSTRAINTS = {
    users_project_kind_check: "project_kind IS NULL OR project_kind IN ('game', 'website', 'app', 'tool', 'hardware', 'undecided')",
    users_project_idea_length_check: "char_length(project_idea) <= 500",
    users_coding_time_check: "coding_time IS NULL OR coding_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'",
    users_onboarding_step_check: "onboarding_step BETWEEN 0 AND 4",
    users_coding_days_check: "coding_days BETWEEN 0 AND 127",
    users_verification_status_check: "verification_status IN ('needs_submission', 'pending', 'verified', 'ineligible')"
  }.freeze

  def change
    # Added NOT VALID first, then validated: if an existing row breaks a rule the migration fails
    # (and rolls back) instead of silently leaving an unchecked constraint behind.
    CONSTRAINTS.each do |name, expression|
      add_check_constraint :users, expression, name: name, validate: false
      validate_check_constraint :users, name: name
    end
  end
end
