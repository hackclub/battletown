module Quests
  # Pays waiting quest rewards when a ship is approved. Subscribed once at boot (config/initializers/quests.rb) to the
  # event the ship code already fires:
  #
  #   ship_approved.battletown (ship_id)  -> Quests::Evaluate for that ship's user (records anything newly done, then pays)
  #
  # `Ships::Approve` fires it AFTER its transaction has committed, so the ship is already approved and its own coins are
  # already in the ledger when this runs, and a failure here can never undo or block an approval. The handler runs in
  # the approving staff member's request, so it swallows every error and logs the class name only; anything it missed is
  # paid by the next dashboard load, ship approval or `rake quests:evaluate` (the payout looks for the user's approved
  # ships itself, so no event is ever required). A duplicate event is harmless: the ledger key makes a second pay a no-op.
  # Does nothing while the Flipper flag `quests` is off.
  module Triggers
    EVENT = "ship_approved.battletown".freeze

    module_function

    def subscribe!
      ActiveSupport::Notifications.subscribe(EVENT) do |*, payload|
        Quests::Triggers.ship_approved(payload)
      end
    end

    def ship_approved(payload)
      return unless Features.enabled?(:quests)

      ActiveRecord::Base.transaction(requires_new: true) do
        ship = Ship.includes(:user).find_by(id: payload[:ship_id])
        Evaluate.call(ship.user) if ship&.status_approved?
      end
    rescue StandardError => error
      Rails.logger.error("quests ship_approved failed error=#{error.class}")
    end
  end
end
