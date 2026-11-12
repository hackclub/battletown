module Game
  # Local-day maths. A "day" is the user's local calendar date in users.time_zone (UTC when blank or unknown). It is
  # settled at the next local midnight plus the grace period. All calendar maths goes through the zone's own
  # calendar (never "+ 24.hours", which is wrong on a DST day). Pure: no database, no clock (callers pass `now`).
  module Days
    module_function

    # An ActiveSupport::TimeZone for a name (Rails name or IANA id); UTC for nil, blank, non-strings and unknown names.
    def zone(name)
      return ActiveSupport::TimeZone["UTC"] unless name.is_a?(String) && name.present?

      ActiveSupport::TimeZone[name] || ActiveSupport::TimeZone["UTC"]
    end

    # The local calendar date of an instant in a zone (a TimeZone or a zone name).
    def local_date(instant, zone_or_name)
      instant.in_time_zone(to_zone(zone_or_name)).to_date
    end

    # The UTC instant at which `date` becomes settled: local midnight at the start of the next date, plus the grace
    # period as elapsed time. A midnight that does not exist (DST gap) resolves to the first valid local instant.
    def settles_at(date, zone_or_name, grace_seconds: Config.current.grace_seconds)
      zone = to_zone(zone_or_name)
      following = date + 1
      (zone.local(following.year, following.month, following.day) + grace_seconds).utc
    end

    def settled?(date, zone_or_name, now, grace_seconds: Config.current.grace_seconds)
      now >= settles_at(date, zone_or_name, grace_seconds: grace_seconds)
    end

    # The latest local date that is settled at `now`.
    def last_settled_date(now, zone_or_name, grace_seconds: Config.current.grace_seconds)
      zone = to_zone(zone_or_name)
      date = local_date(now, zone) - 1
      date -= 1 until settled?(date, zone, now, grace_seconds: grace_seconds)
      date
    end

    def to_zone(zone_or_name)
      zone_or_name.is_a?(ActiveSupport::TimeZone) ? zone_or_name : zone(zone_or_name)
    end
  end
end
