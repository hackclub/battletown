module Teams
  # Pays the crew bonus for ONE approved ship, once. Called after approval (Teams::Triggers, on `ship_approved.battletown`,
  # which fires after the approval transaction commits) and by the retry scan (Teams::PayPending). It is idempotent in two
  # ways that agree: the ledger row has the key `team_bonus:ship:<id>`, and the `team_payouts` row (unique per ship) is the
  # marker that the ship was looked at, written in the same transaction (even when the bonus is 0). So a second call, a second
  # worker or a retry finds the marker and does nothing, and a retry never pays later on different data.
  #
  # Under the earner's row lock: the ship must be approved; the earner must be in a crew now (leaving before the payout means
  # nothing to pay, the rule is "in for the whole date"); the crewmates' counted seconds for the ship's dates are read with
  # Hours::Totals; only dates that are SETTLED for the earner (the same grace rule the streak bonus uses, so a crewmate's late
  # Hackatime sync has landed) can match. A ship approved while one of its counted dates is still inside that grace period
  # (the day of approval, or the morning after) WAITS: no marker and no coins yet, status :waiting, and `team:pay_pending`
  # pays the whole ship once every date has settled. (Paying the settled dates now and writing the marker would lose the
  # newest day's bonus for good.) Staff approval is not affected by anything here: a failure is logged by class name only and
  # `team:pay_pending` tries again.
  #
  # Returns a Result whose status is :disabled, :not_approved, :no_crew, :already_paid, :waiting or :paid.
  module PayShip
    Result = Data.define(:status, :coins, :matched_days) do
      def paid? = status == :paid
    end

    module_function

    def call(ship, now: Time.current, config: Config.current, game_config: Game::Config.current)
      return Result.new(status: :disabled, coins: 0, matched_days: 0) unless Features.enabled?(:team)

      user = ship.user
      user.with_lock do
        fresh = Ship.find(ship.id)
        next skipped(:not_approved) unless fresh.status_approved? && fresh.approved_seconds.to_i.positive?
        next skipped(:already_paid) if TeamPayout.exists?(ship_id: fresh.id)

        membership = TeamMembership.find_by(user_id: user.id)
        next skipped(:no_crew) unless membership
        next skipped(:waiting) if unsettled_dates(fresh, user, now).any?

        outcome = bonus_for(fresh, user, membership, now, game_config, config)
        coins = outcome.bonus_coins
        TeamPayout.create!(user: user, ship: fresh, team_id: membership.team_id, coins: coins, matched_days: outcome.matched_dates.size)
        if coins.positive?
          Coins::Ledger.credit(user: user, amount: coins, kind: "team_bonus", idempotency_key: key(fresh), reference: fresh, created_by: "team_bonus")
        end
        Result.new(status: :paid, coins: coins, matched_days: outcome.matched_dates.size)
      end
    end

    def key(ship) = "team_bonus:ship:#{ship.id}"

    # The ship's counted dates whose streak day is not final yet for the earner (still inside the settling grace period).
    def unsettled_dates(ship, user, now)
      zone = Hours::Days.zone(user.time_zone)
      first_counted = Hours::Days.first_counted_date(user)
      ship.daily_seconds_by_date.keys.select { |date| date >= first_counted && !Game::Days.settled?(date, zone, now) }
    end

    def bonus_for(ship, user, membership, now, game_config, config)
      by_date = ship.daily_seconds_by_date
      range = by_date.keys.min..by_date.keys.max
      earner_zone = Hours::Days.zone(user.time_zone)
      first_counted = Hours::Days.first_counted_date(user)
      eligible = by_date.keys.select { |date| date >= first_counted && Game::Days.settled?(date, earner_zone, now) }

      mates = TeamMembership.where(team_id: membership.team_id).where.not(user_id: user.id).includes(:user).map do |other|
        Bonus::Member.new(joined_at: other.joined_at, zone: Hours::Days.zone(other.user.time_zone),
                          seconds_by_date: Hours::Totals.seconds_by_date(other.user, range))
      end
      earner = Bonus::Member.new(joined_at: membership.joined_at, zone: earner_zone, seconds_by_date: by_date)
      Bonus.call(approved_seconds: ship.approved_seconds, coded_seconds_by_date: by_date, earner: earner, crewmates: mates,
                 threshold: Hours::Config.current.active_seconds, bps: config.bonus_bps, eligible_dates: eligible, game_config: game_config)
    end

    def skipped(status) = Result.new(status: status, coins: 0, matched_days: 0)
    private_class_method :bonus_for, :unsettled_dates, :skipped
  end
end
