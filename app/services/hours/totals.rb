module Hours
  # Read API over the ledger, for the dashboard, boss, streaks and coins. All values are integer seconds and are the net
  # of every row (credits and adjustments), floored at zero. Dates are the frozen local dates on the rows, so ranges are
  # plain date ranges (Date..Date inclusive, Date...Date exclusive, endless and beginless work too).
  #
  # Only COUNTED dates are read: a user's entries dated before `Hours::Days.first_counted_date(user)` (the local date
  # they signed up on, by default) stay in the ledger but are left out of every total here, for the boss as much as
  # for the user's own numbers.
  module Totals
    module_function

    # { Date => seconds } for one user; dates without a row are absent.
    def seconds_by_date(user, range)
      counted_for(user, range).group(:local_date).sum(:seconds)
                              .transform_values { |seconds| [ seconds, 0 ].max }.select { |_, seconds| seconds.positive? }
    end

    # Seconds one user has on one local date (0 when none).
    def seconds_for_date(user, date) = [ counted_for(user, date).sum(:seconds), 0 ].max

    # Seconds across ALL users in a date range (the boss). Aggregate only: no user is identifiable from it.
    def seconds_in_range(range) = [ counted.where(local_date: range).sum(:seconds), 0 ].max

    # How many users have at least `active_seconds` (default 15 minutes, config/game.yml) on that local date.
    def active_user_count(date, minimum: Config.current.active_seconds)
      per_user = counted.where(local_date: date).group("hour_entries.user_id")
                        .having("SUM(hour_entries.seconds) >= ?", minimum).select("hour_entries.user_id")
      HourEntry.from(per_user, :active_users).count
    end

    # { Date => seconds } for one user straight from the ledger, counted or not. For the development ledger page only:
    # the game reads seconds_by_date.
    def ledger_seconds_by_date(user, range)
      HourEntry.where(user_id: user.id, local_date: range).group(:local_date).sum(:seconds)
    end

    # One user's entries on counted dates inside `range` (a Date or a range).
    def counted_for(user, range)
      HourEntry.where(user_id: user.id, local_date: range).where(local_date: Days.first_counted_date(user)..)
    end

    # Every user's entries on counted dates: the same rule as Days.first_counted_date, worked out in SQL. users.created_at
    # is UTC; its local date comes from the user's zone through the zone's IANA id (an unknown or blank zone is UTC, as
    # in Ruby).
    def counted(config: Config.current)
      HourEntry.joins(:user).joins(zone_join)
               .where("hour_entries.local_date >= ((users.created_at AT TIME ZONE 'UTC') AT TIME ZONE COALESCE(user_zones.iana, 'UTC'))::date - CAST(? AS integer)",
                      config.days_before_signup_counted)
    end

    # A VALUES list mapping every Rails zone name (what users.time_zone holds) and IANA id to the IANA id, limited to
    # the ids this PostgreSQL knows so an older zone database can never make the boss query fail. Built once per process.
    def zone_join
      @zone_join ||= begin
        connection = HourEntry.connection
        known = connection.select_values("SELECT name FROM pg_timezone_names").to_set
        rows = ActiveSupport::TimeZone.all.flat_map { |zone| [ [ zone.name, zone.tzinfo.name ], [ zone.tzinfo.name, zone.tzinfo.name ] ] }
                                      .uniq(&:first).select { |_, iana| known.include?(iana) }
        values = rows.map { |name, iana| "(#{connection.quote(name)}, #{connection.quote(iana)})" }.join(", ")
        "LEFT JOIN (VALUES #{values}) AS user_zones(name, iana) ON user_zones.name = users.time_zone".freeze
      end
    end
    private_class_method :zone_join
  end
end
