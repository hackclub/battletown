require "test_helper"
require Rails.root.join("db/migrate/20261113020002_backfill_first_projects")

# The data migration that copies users.project_kind / project_idea into a first active project.
class BackfillFirstProjectsTest < ActiveSupport::TestCase
  def run_backfill = ActiveRecord::Migration.suppress_messages { BackfillFirstProjects.new.backfill }

  test "copies kind and idea into one active project and leaves the user columns alone" do
    user = users(:onboarded)
    user.update!(project_kind: "game", project_idea: "A farming game. With cows.")
    run_backfill
    project = user.projects.sole
    assert_equal "A farming game", project.name
    assert_equal "game", project.kind
    assert_equal "A farming game. With cows.", project.idea
    assert project.active?
    assert project.status_active?
    assert_equal [ "game", "A farming game. With cows." ], user.reload.values_at(:project_kind, :project_idea)
  end

  test "a kind alone gets a default name and users with neither get no project" do
    users(:onboarded).update!(project_kind: "tool", project_idea: nil)
    users(:new_user).update!(project_kind: nil, project_idea: "  ")
    run_backfill
    assert_equal "My tool", users(:onboarded).projects.sole.name
    assert_equal 0, users(:new_user).projects.count
  end

  test "an idea with no kind becomes an undecided project" do
    users(:new_user).update!(project_kind: nil, project_idea: "Something cool")
    run_backfill
    assert_equal "undecided", users(:new_user).projects.sole.kind
  end

  test "running again, or for a user who already has a project, adds nothing" do
    user = users(:onboarded)
    Project.create!(user: user, name: "Existing")
    run_backfill
    run_backfill
    assert_equal [ "Existing" ], user.projects.pluck(:name)
  end
end
