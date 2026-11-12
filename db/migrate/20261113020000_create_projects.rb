# A project is the thing a teen builds and ships. A user may have many (at most 10, enforced in the model) but
# exactly one is the "active" one at a time: the partial unique index below is what guarantees it.
# Allowlists are written out literally (not read from model constants) so this migration keeps working if
# the constants change later; keep them in sync with app/models/project.rb and User::PROJECT_KINDS.
class CreateProjects < ActiveRecord::Migration[8.1]
  GITHUB_REPO = '^https://github\.com/[a-z0-9-]{1,39}/(?!\.+$)[a-z0-9._-]{1,100}$'.freeze

  def change
    create_table :projects do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :name, null: false
      t.string :kind, null: false, default: "undecided"
      t.text :idea
      t.string :repo_url
      t.string :demo_url
      t.string :status, null: false, default: "active"
      t.string :guide_key
      t.boolean :active, null: false, default: false
      t.timestamps
    end

    add_index :projects, [ :user_id, :created_at ]
    add_index :projects, :user_id, unique: true, where: "active", name: "index_projects_one_active_per_user"
    # Lets hackatime_links point at (id, user_id) so a link can never belong to a different user than its project.
    add_index :projects, [ :id, :user_id ], unique: true, name: "index_projects_on_id_and_user_id"

    add_check_constraint :projects, "char_length(name) BETWEEN 1 AND 60 AND btrim(name) <> ''", name: "projects_name_check"
    add_check_constraint :projects, "kind IN ('game', 'website', 'app', 'tool', 'hardware', 'undecided')", name: "projects_kind_check"
    add_check_constraint :projects, "char_length(idea) <= 500", name: "projects_idea_length_check"
    add_check_constraint :projects, "repo_url IS NULL OR (char_length(repo_url) <= 300 AND repo_url ~ '#{GITHUB_REPO}')", name: "projects_repo_url_check"
    add_check_constraint :projects, "demo_url IS NULL OR (char_length(demo_url) <= 300 AND demo_url ~ '^https://[^[:space:]/?#@]+([/?#][^[:space:]]*)?$')", name: "projects_demo_url_check"
    add_check_constraint :projects, "status IN ('active', 'archived')", name: "projects_status_check"
    add_check_constraint :projects, "guide_key IS NULL OR guide_key IN ('sd', 'playground')", name: "projects_guide_key_check"
    # The one active project can never be an archived one.
    add_check_constraint :projects, "NOT active OR status = 'active'", name: "projects_active_not_archived_check"
  end
end
