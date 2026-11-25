# The dashboard's "what are you going to do this commit?" list: a few short items per project (what to work on this commit, at most ten), kept as a JSON array of
# {"body", "done"}. A column (not a table) so deleting a project, or the person, deletes it with no new place for personal text.
class AddTodosToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :todos, :jsonb, null: false, default: []
    add_check_constraint :projects, "jsonb_typeof(todos) = 'array' AND jsonb_array_length(todos) <= 10", name: "projects_todos_check"
  end
end
