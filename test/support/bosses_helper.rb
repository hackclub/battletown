# Shared helpers for the boss tests. Dates are fixed (a Friday to a Thursday) so nothing depends on the clock.
module BossesHelper
  FRIDAY = Date.new(2026, 11, 13)
  THURSDAY = Date.new(2026, 11, 19)
  HOUR = 3600

  def make_boss(starts_on: FRIDAY, ends_on: starts_on + 6, hp_seconds: 500 * HOUR, **attrs)
    Boss.create!({ name: "Boss #{starts_on}", art_key: "placeholder", starts_on: starts_on, ends_on: ends_on, hp_seconds: hp_seconds }.merge(attrs))
  end

  # The Friday a boss week covering `date` starts on (`date` itself when it is a Friday). A boss week is always Friday to Thursday.
  def friday_on_or_before(date) = date - ((date.wday - 5) % 7)

  # One ledger row holds at most a day, so a bigger total (hundreds of hours) is split over several rows. Returns the
  # last row written.
  def add_hours(user, date, seconds, source: "manual")
    sign = seconds.positive? ? 1 : -1
    chunks = seconds.abs.divmod(HourEntry::MAX_SECONDS).then { |full, rest| [ HourEntry::MAX_SECONDS ] * full + [ rest ] }.reject(&:zero?)
    chunks.map do |chunk|
      HourEntry.create!(user: user, local_date: date, seconds: sign * chunk, source: source, note: "test", idempotency_key: SecureRandom.hex(8))
    end.last
  end

  # Damages the boss the way the game does: a ship by `user` with `seconds` of coded time, SUBMITTED on `on` (a Date, taken as
  # noon UTC, or a Time). Pass `status:` to make a ship that must not count ("draft", "withdrawn", "rejected") or one that
  # counts at its approved hours ("approved", with `approved_seconds:`, which defaults to all of them). Builds the row
  # straight away (no hours ledger, no Ships::Submit), on a project of the user's that has no open ship, or a new one, so
  # it can be called many times for one user. Does not run Bosses::CheckDefeat: call it yourself, or use Ships::Submit.
  def ship_damage(user, seconds, on: FRIDAY, status: "submitted", approved_seconds: nil)
    at = on.is_a?(Date) ? on.in_time_zone("UTC").change(hour: 12) : on
    project = user.projects.where.not(id: Ship.open_now.where(user_id: user.id).select(:project_id)).first || damage_project(user)
    day = at.utc.to_date
    attrs = { user: user, project: project, status: status, description: "Hit the boss.", repo_url: "https://github.com/octo/boss-hit",
              coded_seconds: seconds, window_start_date: day, window_end_date: day, daily_seconds: { day.iso8601 => seconds } }
    attrs[:submitted_at] = at unless status == "draft"
    attrs.merge!(approved_seconds: approved_seconds || seconds, reviewed_at: at) if status == "approved"
    attrs.merge!(rejection_reason: "Not yet", reviewed_at: at) if status == "rejected"
    Ship.create!(attrs)
  end

  # A spare project for ship_damage that is not the user's active one. Skips validation so a test can make more than
  # Project::MAX_PER_USER of them.
  def damage_project(user)
    Project.new(user: user, name: "Damage #{SecureRandom.hex(4)}", kind: "game", active: false).tap { |project| project.save!(validate: false) }
  end
end
