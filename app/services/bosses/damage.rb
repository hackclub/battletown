module Bosses
  # The damage a boss has taken: the coded hours on the ships people SUBMITTED during its week. Coding alone never hurts
  # the boss; shipping does. Derived, never stored. Aggregate only (a sum, no names).
  #
  # - Which ships: status `submitted` or `approved` (Ship::WINDOW_STATUSES). A draft has not been shipped, a withdrawn ship
  #   was taken back, and a rejected ship gave its window back: "Fix and ship again" submits the same hours as a NEW ship,
  #   so counting rejected ones would hit the boss twice.
  # - How much: `COALESCE(approved_seconds, coded_seconds)`. Staff can only lower approved hours, so a reviewer lowering
  #   them lowers the damage. The coin deflation never applies here (it is coins only).
  # - Which week: the UTC date of `submitted_at` against the boss's dates (Friday to Thursday), so a boss week is the
  #   same instant for everybody: Friday 00:00 UTC up to, not including, the next Friday 00:00 UTC.
  # - Floored at zero (cannot go below it anyway).
  module Damage
    SECONDS = "COALESCE(ships.approved_seconds, ships.coded_seconds)".freeze

    module_function

    def for(boss) = BossMath.damage(ships_in(boss).sum(Arel.sql(SECONDS)))

    # One person's own ships in the boss's week (what the card calls "you've dealt").
    def for_user(boss, user) = BossMath.damage(ships_in(boss).where(user_id: user.id).sum(Arel.sql(SECONDS)))

    # One person's damage over every boss week so far (all their submitted and approved ships, whichever week). A single sum;
    # it is what a profile shows as "all-time".
    def all_time_for_user(user) = BossMath.damage(Ship.where(status: Ship::WINDOW_STATUSES, user_id: user.id).sum(Arel.sql(SECONDS)))

    # How many fallen bosses this person earned the Boss slayer badge on: their own submitted or approved ships inside the boss's
    # week add up to at least `slayer_seconds`. One grouped query (each boss week against this person's ships).
    def slain_count(user, slayer_seconds: Config.current.slayer_seconds)
      Boss.where.not(defeated_at: nil)
          .joins(Boss.sanitize_sql_array([ "INNER JOIN ships ON ships.user_id = ? AND ships.status IN (?) AND ships.submitted_at >= bosses.starts_on " \
                                          "AND ships.submitted_at < (bosses.ends_on + 1)", user.id, Ship::WINDOW_STATUSES ]))
          .group("bosses.id").having("SUM(#{SECONDS}) >= ?", slayer_seconds).count.size
    end

    # The ships that count toward a boss. Never shown with names: callers only sum it.
    def ships_in(boss) = Ship.where(status: Ship::WINDOW_STATUSES, submitted_at: week_times(boss))

    # The boss's dates as a UTC time range: [Friday 00:00, next Friday 00:00).
    def week_times(boss) = boss.starts_on.in_time_zone("UTC")...(boss.ends_on + 1).in_time_zone("UTC")
  end
end
