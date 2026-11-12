module Ships
  # A ship's own snapshot as the daily-seconds source Coins::ApproveShip reads (`seconds_by_date(user, range)`), so
  # the payout is spread over what was submitted, however the live ledger or the links have changed since.
  class SnapshotSource
    def initialize(ship)
      @by_date = ship.daily_seconds_by_date
    end

    def seconds_by_date(_user, range)
      @by_date.select { |date, _| range.cover?(date) }
    end
  end
end
