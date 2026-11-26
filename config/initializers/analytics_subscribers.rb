# Subscribes the product analytics events (app/services/analytics/subscribers.rb) to the ship and order events the code already announces. Runs
# once at boot, after the app is loaded; the subscriber block resolves the handler when an event fires, so code reloading keeps working and
# nothing is subscribed twice. A failure in a handler is logged by class and swallowed: it can never break a ship decision or an order change.
Rails.application.config.after_initialize do
  Analytics::Subscribers.subscribe!
end
