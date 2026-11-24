# Onboarding gained an age step at index 0 and a sign-up step at index 4
# (age, prize, project, schedule, signup, account, celebrate), so the steps after each move up. Users keep the place
# they had: prize/project/schedule 0..2 -> 1..3, account 3 -> 5, celebrate 4 -> 6.
class AddSignupStepToOnboarding < ActiveRecord::Migration[8.1]
  def up
    remove_check_constraint :users, name: "users_onboarding_step_check"
    add_check_constraint :users, "onboarding_step BETWEEN 0 AND 6", name: "users_onboarding_step_check"
    execute "UPDATE users SET onboarding_step = onboarding_step + CASE WHEN onboarding_step >= 3 THEN 2 ELSE 1 END"
  end

  def down
    execute "UPDATE users SET onboarding_step = GREATEST(onboarding_step - CASE WHEN onboarding_step >= 5 THEN 2 ELSE 1 END, 0)"
    remove_check_constraint :users, name: "users_onboarding_step_check"
    add_check_constraint :users, "onboarding_step BETWEEN 0 AND 4", name: "users_onboarding_step_check"
  end
end
