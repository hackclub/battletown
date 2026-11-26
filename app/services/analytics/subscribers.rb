module Analytics
  # Product events taken from the game events the code already announces, so the ship and order services stay untouched by analytics.
  # Subscribed once at boot (config/initializers/analytics_subscribers.rb), like Quests::Triggers and Teams::Triggers: the block finds the
  # handler when an event fires, so code reloading keeps working and nothing is subscribed twice.
  #
  #   ship_submitted.battletown (ship_id)  -> ship_submitted and boss_hit
  #   ship_approved.battletown  (ship_id)  -> ship_approved
  #   ship_rejected.battletown  (ship_id)  -> ship_rejected
  #   ship_withdrawn.battletown (ship_id)  -> ship_withdrawn   (a submitted ship taken back; Ships::Withdraw)
  #   order_shipped / order_fulfilled / order_cancelled / order_refunded.battletown (order_id, actor_kind) -> the event of the same name
  #
  # The services fire these AFTER their transaction committed, in the request that did the work, so a handler swallows every error (class name
  # only, Analytics::Product.guard): a problem here can never undo or block a ship decision or an order change, nor stop the handlers after it.
  module Subscribers
    SHIPS = { "ship_submitted.battletown" => :ship_submitted, "ship_approved.battletown" => :ship_approved,
              "ship_rejected.battletown" => :ship_rejected, "ship_withdrawn.battletown" => :ship_withdrawn }.freeze
    ORDERS = %w[order_shipped order_fulfilled order_cancelled order_refunded].freeze

    module_function

    def subscribe!
      SHIPS.each do |event, handler|
        ActiveSupport::Notifications.subscribe(event) do |*, payload|
          Analytics::Subscribers.ship(handler, payload)
        end
      end
      ORDERS.each do |name|
        ActiveSupport::Notifications.subscribe("#{name}.battletown") do |*, payload|
          Analytics::Subscribers.order(name, payload)
        end
      end
    end

    def ship(handler, payload)
      Product.guard(handler) { Product.public_send(handler, Ship.includes(:user).find_by(id: payload[:ship_id])) }
    end

    def order(name, payload)
      Product.order_changed(name, payload[:order_id], payload[:actor_kind])
    end
  end
end
