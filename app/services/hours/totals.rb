module Hours
  # Read API over the ledger, for the dashboard, boss, streaks and coins. All values are integer seconds and are the net
  # of every row (credits and adjustments), floored at zero. Dates are the frozen local dates on the rows, so ranges are
  # plain date ranges (Date..Date inclusive, Date...Date exclusive, endless and beginless work too).
  module Totals
    module_function

    # { Date => seconds } for one user; dates without a row are absent.
    def seconds_by_date(user, range)
      HourEntry.where(user_id: user.id, local_date: range).group(:local_date).sum(:seconds)
               .transform_values { |seconds| [ seconds, 0 ].max }.select { |_, seconds| seconds.positive? }
    end

    # Seconds one user has on one local date (0 when none).
    def seconds_for_date(user, date) = [ HourEntry.where(user_id: user.id, local_date: date).sum(:seconds), 0 ].max

    # Seconds across ALL users in a date range (the boss). Aggregate only: no user is identifiable from it.
    def seconds_in_range(range) = [ HourEntry.where(local_date: range).sum(:seconds), 0 ].max

    # How many users have at least `active_seconds` (default 15 minutes, config/game.yml) on that local date.
    def active_user_count(date, minimum: Config.current.active_seconds)
      per_user = HourEntry.where(local_date: date).group(:user_id).having("SUM(seconds) >= ?", minimum).select(:user_id)
      HourEntry.from(per_user, :active_users).count
    end
  end
end
