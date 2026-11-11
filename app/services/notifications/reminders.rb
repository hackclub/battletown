module Notifications
  # Pure reminder arithmetic: no database, no network. Works on anything that responds to `coding_days`
  # (bitmask, Monday = 1 .. Sunday = 64), `coding_time` ("HH:MM") and `time_zone` (an ActiveSupport::TimeZone name).
  #
  # A reminder is due on every selected local weekday at the local wall-clock `coding_time` in the user's zone.
  # Anything missing or invalid (no days, no time, unknown zone) yields nil: we never guess UTC.
  #
  # Daylight saving rules (each selected local day yields exactly one reminder):
  # - Spring-forward gap (the wall-clock time does not exist, e.g. 02:30 on 2027-03-14 in New York): the reminder
  #   fires at the first valid instant after the gap (03:00 local), once, never twice and never skipped.
  # - Fall-back overlap (the wall-clock time happens twice, e.g. 01:30 on 2026-11-01 in New York): it fires once,
  #   at the first (earlier) occurrence.
  # - A local calendar day that does not exist at all (Pacific/Apia skipped 2011-12-30) is treated as a gap: the
  #   reminder fires at the first valid instant after it.
  module Reminders
    TIME_FORMAT = /\A([01]\d|2[0-3]):([0-5]\d)\z/
    # Candidate local dates start one day before `after` (a gap can push a reminder across midnight) and run a
    # week plus a day beyond it, which always contains the next selected weekday.
    LOOKBACK_DAYS = 1
    LOOKAHEAD_DAYS = 8
    GAP_SEARCH_WINDOW = 2 * 24 * 3600

    module_function

    # The next UTC Time strictly after `after` at which the user's daily reminder is due, or nil.
    def due_at(user, after:)
      zone, days, hour, minute = schedule_for(user)
      return nil unless zone

      after = after.to_time
      first_date = after.in_time_zone(zone).to_date - LOOKBACK_DAYS
      (0..(LOOKBACK_DAYS + LOOKAHEAD_DAYS)).each do |offset|
        date = first_date + offset
        next unless days.anybits?(1 << (date.cwday - 1))

        instant = instant_for(zone, date, hour, minute)
        return instant if instant > after
      end
      nil
    end

    # Every due instant `t` with `from < t <= to`, ascending. Capped, so a huge range cannot run away.
    def due_between(user, from:, to:, limit: 400)
      results = []
      cursor = from
      while results.size < limit && (instant = due_at(user, after: cursor)) && instant <= to
        results << instant
        cursor = instant
      end
      results
    end

    # True when `instant` is exactly one of the user's due instants (used to spot a changed schedule).
    def scheduled?(user, instant)
      instant = instant.to_time.utc
      due_at(user, after: instant - 1) == instant
    end

    # The UTC instant for wall-clock hour:minute on a local calendar date, following the DST rules above.
    def instant_for(zone, date, hour, minute)
      tz = zone.tzinfo
      local = Time.utc(date.year, date.month, date.day, hour, minute)
      utc = begin
        # Ambiguous (fall back): the block receives both candidate periods; take the earlier instant.
        tz.local_to_utc(local) { |periods| periods.min_by { |period| local - period.utc_total_offset } }
      rescue TZInfo::PeriodNotFound
        gap_end(tz, local)
      end
      utc.utc
    end

    # The first valid instant after the gap that contains the wall-clock time `local`.
    def gap_end(tz, local)
      transitions = tz.transitions_up_to(local + GAP_SEARCH_WINDOW, local - GAP_SEARCH_WINDOW)
      transitions.min_by { |transition| (transition.at.to_time - local).abs }.at.to_time.utc
    end

    # Returns [zone, days, hour, minute], or nil for any missing or invalid input.
    def schedule_for(user)
      days = user.coding_days
      return nil unless days.is_a?(Integer) && days.between?(1, 127)

      match = TIME_FORMAT.match(user.coding_time.to_s)
      return nil unless match

      zone = lookup_zone(user.time_zone)
      return nil unless zone

      [ zone, days, match[1].to_i, match[2].to_i ]
    end

    def lookup_zone(name)
      return nil unless name.is_a?(String) && name.present?

      ActiveSupport::TimeZone[name]
    end
  end
end
