# Builders for the Plinko tests. Dates are fixed so nothing depends on the clock.
module PlinkoHelper
  def minutes(count) = count * 60

  # Counted coded time on a local date (the fixture users signed up long before any test date).
  def code_on(user, date, seconds)
    HourEntry.create!(user: user, local_date: date, seconds: seconds, source: "manual", note: "plinko test", idempotency_key: SecureRandom.hex(8))
  end

  # A ball already dropped on a local date, written straight to the table (no ball check).
  def dropped_on(user, date, slot: 4, seed: nil)
    board = Plinko::Board.current
    PlinkoDrop.create!(user: user, dropped_at: date.in_time_zone("UTC") + 12.hours, local_date: date, slot: slot, points: board.points_for(slot),
                       seed: seed || SecureRandom.random_number(1 << 40), idempotency_key: SecureRandom.hex(8))
  end

  def balls_for(user, now) = Plinko::Balls.for(user, now: now)
end
