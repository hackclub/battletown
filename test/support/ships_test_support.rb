require "test_helper"

# Builders for the ship tests. Dates are fixed so nothing depends on the clock.
module ShipsTestSupport
  HOUR = 3600
  REPO = "https://github.com/octo/space-farm".freeze

  # A project with one linked Hackatime project ("space-farm") for the user.
  def make_project(user, name: "Space Farm", hackatime: "space-farm")
    project = Project.create!(user: user, name: name, kind: "game")
    project.hackatime_links.create!(user_id: user.id, hackatime_project: hackatime, link_method: "manual") if hackatime
    project
  end

  # Coded time on a local date for one Hackatime project (a ledger row holds at most a day).
  def code(user, date, seconds, hackatime: "space-farm")
    HourEntry.create!(user: user, local_date: date, seconds: seconds, source: "manual", note: "test", hackatime_project: hackatime,
                      idempotency_key: SecureRandom.hex(8))
  end

  def ship_attrs(**extra) = { description: "Built the cow physics.", repo_url: REPO }.merge(extra)

  def submit_ship(project, submit: true, **attrs)
    Ships::Submit.call(project: project, attributes: ship_attrs(**attrs), submit: submit)
  end

  # Raw INSERT of a ship (bypasses the model) to prove the database refuses bad rows.
  def raw_ship_values(user, project, **overrides)
    { user_id: user.id, project_id: project.id, status: "submitted", description: "d", repo_url: REPO, coded_seconds: 3600,
      window_start_date: "2026-11-09", window_end_date: "2026-11-09", daily_seconds: '{"2026-11-09": 3600}',
      submitted_at: "2026-11-10 12:00:00", created_at: "2026-11-10 12:00:00", updated_at: "2026-11-10 12:00:00" }.merge(overrides)
  end

  def insert_ship_sql!(values)
    connection = ActiveRecord::Base.connection
    columns = values.keys.map { |key| connection.quote_column_name(key) }.join(", ")
    quoted = values.values.map { |value| connection.quote(value) }.join(", ")
    connection.execute("INSERT INTO ships (#{columns}) VALUES (#{quoted})")
  end
end
