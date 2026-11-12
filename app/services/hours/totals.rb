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

    # Every user's entries on counted dates: the same rule as Days.first_counted_date, worked out in SQL from the
    # frozen `users.signed_up_on`.
    def counted(config: Config.current)
      HourEntry.joins(:user)
               .where("hour_entries.local_date >= users.signed_up_on - CAST(? AS integer)", config.days_before_signup_counted)
    end
  end
end
