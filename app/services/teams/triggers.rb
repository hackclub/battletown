module Teams
  # Pays the crew bonus when a ship is approved, without the approval code knowing: subscribed once at boot
  # (config/initializers/team_triggers.rb) to `ship_approved.battletown`, which Ships::Approve fires AFTER its transaction
  # commits, so the base and streak coins are already safe. The handler does nothing while the `team` flag is off, runs in a
  # savepoint and swallows any error (logging only the class name), so a problem here can never break a staff approval;
  # Teams::PayPending (`rake team:pay_pending`) picks up what failed. A duplicate event pays nothing twice (Teams::PayShip).
  module Triggers
    EVENT = "ship_approved.battletown".freeze

    module_function

    def subscribe!
      ActiveSupport::Notifications.subscribe(EVENT) do |*, payload|
        Teams::Triggers.ship_approved(payload)
      end
    end

    def ship_approved(payload)
      return unless Features.enabled?(:team)

      ship = Ship.includes(:user).find_by(id: payload[:ship_id])
      return unless ship

      ActiveRecord::Base.transaction(requires_new: true) { PayShip.call(ship) }
    rescue StandardError => error
      Rails.logger.error("teams: bonus for an approved ship failed error=#{error.class}")
    end
  end
end
