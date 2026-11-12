module Coins
  # What the ship flow calls when staff approve a ship. Credits the user ONCE, however many times it is called for the
  # same ship: one `ship_approval` ledger row for the base coins and one `streak_bonus` row for the bonus coins, with
  # idempotency keys derived from the ship reference.
  #
  # Steps: settle the user's finished days; read each window date's settled bonus_bps and its coded seconds; compute
  # the payout with Coins::ShipPayout; write the rows in one transaction under the user lock. A zero amount writes no
  # row (the ledger refuses zero).
  #
  # Window dates that are not settled yet (today, or yesterday inside the grace period) earn no bonus: a bonus is
  # only paid on a day whose streak is final. Dates before the account existed likewise earn none. The dates that
  # got no bonus for being unsettled are returned in `unsettled_dates`.
  #
  # Arguments: `ship_reference` is the ship record (or a [type, id] pair); `approved_seconds` the staff-approved
  # seconds; `window_dates` the local dates the ship covers; `hours_since_previous_ship_before_window` an Integer or
  # Rational number of hours already counted toward the deflation threshold before this window (normally 0).
  module ApproveShip
    Result = Data.define(:base_coins, :bonus_coins, :total_coins, :base_entry, :bonus_entry, :already_approved, :unsettled_dates, :payout)

    module_function

    def call(user:, ship_reference:, approved_seconds:, window_dates:, hours_since_previous_ship_before_window: 0,
             source: nil, now: Time.current, config: Game::Config.current)
      type, id = Ledger.reference_parts(ship_reference)
      raise ArgumentError, "ship_reference is required" if type.nil?

      base_key = "ship_approval:#{type}:#{id}"
      bonus_key = "streak_bonus:#{type}:#{id}"
      dates = Array(window_dates).map(&:to_date).uniq.sort
      raise ArgumentError, "window_dates must not be empty" if dates.empty?

      source ||= Game::HoursSource.current
      Game::Settle.call(user, through: now, source: source, config: config)

      user.with_lock do
        existing = CoinTransaction.where(user_id: user.id, idempotency_key: [ base_key, bonus_key ]).index_by(&:idempotency_key)
        next replay(existing, base_key, bonus_key) if existing.any?

        zone = Game::Days.zone(user.time_zone)
        settled = DailyResult.where(user_id: user.id, local_date: dates).to_h { |row| [ row.local_date, row.bonus_bps ] }
        unsettled = dates.reject { |date| settled.key?(date) || date < Game::Days.local_date(user.created_at, zone) }
        coded = source.seconds_by_date(user, dates.first..dates.last).slice(*dates)
        payout = ShipPayout.call(approved_seconds: approved_seconds, coded_seconds_by_date: dates.to_h { |date| [ date, coded.fetch(date, 0) ] },
                                 bonus_bps_by_date: settled, hours_since_previous_ship_before_window: hours_since_previous_ship_before_window,
                                 config: config)

        base_entry = credit(user, payout.base_coins, "ship_approval", base_key, ship_reference)
        bonus_entry = credit(user, payout.bonus_coins, "streak_bonus", bonus_key, ship_reference)
        Result.new(base_coins: payout.base_coins, bonus_coins: payout.bonus_coins, total_coins: payout.total_coins, base_entry: base_entry,
                   bonus_entry: bonus_entry, already_approved: false, unsettled_dates: unsettled, payout: payout)
      end
    end

    def credit(user, amount, kind, key, reference)
      return nil unless amount.positive?

      Ledger.credit(user: user, amount: amount, kind: kind, idempotency_key: key, reference: reference, created_by: "ship_approval")
    end

    # A second approval of the same ship: report what was credited the first time, write nothing.
    def replay(existing, base_key, bonus_key)
      base = existing[base_key]
      bonus = existing[bonus_key]
      base_coins = base&.amount.to_i
      bonus_coins = bonus&.amount.to_i
      Result.new(base_coins: base_coins, bonus_coins: bonus_coins, total_coins: base_coins + bonus_coins, base_entry: base, bonus_entry: bonus,
                 already_approved: true, unsettled_dates: [], payout: nil)
    end
    private_class_method :credit, :replay
  end
end
