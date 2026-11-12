# The Hackatime project names a ship's window covered, frozen with the rest of the snapshot. Ships::Window starts each
# name after the last submitted or approved ship that covered it, whichever project that name is linked to now, so
# moving a link to another project cannot ship (and pay) the same hours twice.
#
# Existing ships are backfilled with their project's current links. That blocks exactly what the old per-project rule
# blocked for those names, and from now on the block moves with the name. A name that was moved away before this
# migration cannot be recovered; an existing ship left with no names keeps the old per-project rule (Ships::Window).
class AddHackatimeProjectsToShips < ActiveRecord::Migration[8.1]
  def up
    add_column :ships, :hackatime_projects, :string, array: true, null: false, default: []
    backfill
  end

  def down
    remove_column :ships, :hackatime_projects
  end

  # Only fills ships that have no names yet, so running it again changes nothing.
  def backfill
    execute <<~SQL.squish
      UPDATE ships SET hackatime_projects = linked.names
        FROM (SELECT project_id, array_agg(hackatime_project ORDER BY hackatime_project) AS names
                FROM hackatime_links GROUP BY project_id) AS linked
       WHERE linked.project_id = ships.project_id AND ships.hackatime_projects = '{}'
    SQL
  end
end
