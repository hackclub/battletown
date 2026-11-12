# Which Hackatime projects count toward which project. A Hackatime project links to at most one project per user
# (unique on user_id + hackatime_project). Suggestions are "is this yours?" questions; a declined one stays so it is
# never asked again. Both tables are deleted with the user: hackatime_links via user_id and project_id, and
# link_suggestions through its project.
class CreateHackatimeLinksAndLinkSuggestions < ActiveRecord::Migration[8.1]
  NAME_OK = "char_length(hackatime_project) BETWEEN 1 AND 120 AND hackatime_project !~ '[[:cntrl:]]' AND hackatime_project = btrim(hackatime_project)".freeze

  def change
    create_table :hackatime_links do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.bigint :project_id, null: false
      t.string :hackatime_project, null: false
      t.string :link_method, null: false
      t.timestamps
    end

    add_index :hackatime_links, [ :user_id, :hackatime_project ], unique: true, name: "index_hackatime_links_on_user_and_name"
    add_index :hackatime_links, :project_id
    # Composite so a link's user is always its project's owner; cascades when the project (or the user) goes.
    add_foreign_key :hackatime_links, :projects, column: [ :project_id, :user_id ], primary_key: [ :id, :user_id ], on_delete: :cascade
    add_check_constraint :hackatime_links, NAME_OK, name: "hackatime_links_name_check"
    add_check_constraint :hackatime_links, "link_method IN ('manual', 'auto_repo', 'confirmed')", name: "hackatime_links_method_check"

    create_table :link_suggestions do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :hackatime_project, null: false
      t.string :state, null: false, default: "pending"
      t.timestamps
    end

    add_index :link_suggestions, [ :project_id, :hackatime_project ], unique: true, name: "index_link_suggestions_on_project_and_name"
    add_check_constraint :link_suggestions, NAME_OK, name: "link_suggestions_name_check"
    add_check_constraint :link_suggestions, "state IN ('pending', 'accepted', 'declined')", name: "link_suggestions_state_check"
  end
end
