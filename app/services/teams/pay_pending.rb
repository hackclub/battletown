module Teams
  # The retry scan behind `rake team:pay_pending`: finds ships approved within the last `pay_pending_days` days whose
  # owner is in a crew now and that have no `team_payouts` marker yet (the event handler failed, or the flag was off at
  # approval time), and runs Teams::PayShip for each. Safe to repeat and to run from two places at once (PayShip is
  # idempotent). One bad ship never stops the rest. Does nothing, and reads nothing, while the `team` flag is off.
  module PayPending
    Result = Data.define(:scanned, :paid)

    module_function

    def scan(now: Time.current, config: Config.current)
      return Result.new(scanned: 0, paid: 0) unless Features.enabled?(:team)

      scope = Ship.where(status: "approved", reviewed_at: (now - config.pay_pending_days.days)..)
                  .where(user_id: TeamMembership.select(:user_id))
                  .where.not(id: TeamPayout.select(:ship_id))
      scanned = 0
      paid = 0
      scope.includes(:user).find_each do |ship|
        scanned += 1
        result = ActiveRecord::Base.transaction(requires_new: true) { PayShip.call(ship, now: now, config: config) }
        paid += 1 if result.paid?
      rescue StandardError => error
        Rails.logger.error("teams: pay_pending failed error=#{error.class}")
      end
      Result.new(scanned: scanned, paid: paid)
    end
  end
end
