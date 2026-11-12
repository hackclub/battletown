# Shared helpers for the boss tests. Dates are fixed (a Friday to a Thursday) so nothing depends on the clock.
module BossesHelper
  FRIDAY = Date.new(2026, 11, 13)
  THURSDAY = Date.new(2026, 11, 19)
  HOUR = 3600

  def make_boss(starts_on: FRIDAY, ends_on: starts_on + 6, hp_seconds: 500 * HOUR, **attrs)
    Boss.create!({ name: "Boss #{starts_on}", art_key: "placeholder", starts_on: starts_on, ends_on: ends_on, hp_seconds: hp_seconds }.merge(attrs))
  end

  # One ledger row holds at most a day, so a bigger total (hundreds of hours) is split over several rows. Returns the
  # last row written.
  def add_hours(user, date, seconds, source: "manual")
    sign = seconds.positive? ? 1 : -1
    chunks = seconds.abs.divmod(HourEntry::MAX_SECONDS).then { |full, rest| [ HourEntry::MAX_SECONDS ] * full + [ rest ] }.reject(&:zero?)
    chunks.map do |chunk|
      HourEntry.create!(user: user, local_date: date, seconds: sign * chunk, source: source, note: "test", idempotency_key: SecureRandom.hex(8))
    end.last
  end
end
