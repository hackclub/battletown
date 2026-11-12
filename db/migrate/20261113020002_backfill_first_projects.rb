# Copies each existing user's onboarding answers (users.project_kind / users.project_idea) into a first, active
# project. The old user columns are left untouched. Self-contained (plain SQL, no app models) so it keeps working
# if the models change; `backfill` is public so a test can run it.
class BackfillFirstProjects < ActiveRecord::Migration[8.1]
  DANGLING_TAIL = /(?:[\s,;:\-]+(?:a|an|the|in|of|on|to|and|or|for|with|where|that|is|are))*[\s,;:\-]*\z/i
  KIND_NAMES = { "game" => "My game", "website" => "My website", "app" => "My app", "tool" => "My tool", "hardware" => "My hardware project" }.freeze

  def up = backfill

  def down; end

  def backfill
    rows = select_rows(<<~SQL.squish)
      SELECT u.id, u.project_kind, u.project_idea FROM users u
      WHERE (u.project_kind IS NOT NULL OR btrim(coalesce(u.project_idea, '')) <> '')
        AND NOT EXISTS (SELECT 1 FROM projects p WHERE p.user_id = u.id)
    SQL
    rows.each do |id, kind, idea|
      idea = idea.to_s.strip.presence
      execute(<<~SQL.squish)
        INSERT INTO projects (user_id, name, kind, idea, status, active, created_at, updated_at)
        VALUES (#{id.to_i}, #{quote(title_for(kind, idea))}, #{quote(kind || 'undecided')}, #{quote(idea)}, 'active', TRUE, now(), now())
      SQL
    end
  end

  private

  # Same idea as Project.default_name: the first sentence of the idea, shortened, else "My <kind>".
  def title_for(kind, idea)
    title = idea.to_s.split(/[.!?\n]/).first.to_s.squish
    title = title.truncate(40, separator: " ", omission: "").sub(DANGLING_TAIL, "")
    title = title[0].upcase + title[1..] if title.present?
    title.presence || KIND_NAMES.fetch(kind.to_s, "My project")
  end
end
