# A copy of the newest project_reviews row on the project itself, so the staff queue can filter and count without a join.
# Written only with the review row, in one transaction (Projects::Review). Every existing project starts unreviewed.
class AddReviewStatusToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :review_status, :string, null: false, default: "unreviewed"
    add_column :projects, :reviewed_at, :datetime
    add_check_constraint :projects, "review_status IN ('unreviewed', 'ok', 'flagged')", name: "projects_review_status_check"
    add_check_constraint :projects, "(review_status = 'unreviewed') = (reviewed_at IS NULL)", name: "projects_reviewed_at_check"
    add_index :projects, [ :review_status, :created_at ]
  end
end
