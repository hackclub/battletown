# Subscribes the Slack notification handlers (app/services/notifications/triggers.rb) to the game events. Runs once at
# boot, after the app is loaded; the subscriber block resolves the handler class when an event fires, so code
# reloading keeps working and nothing is subscribed twice. The handlers only queue outbox rows: nothing is sent until
# the dispatcher runs with NOTIFICATIONS_ENABLED=true.
Rails.application.config.after_initialize do
  Notifications::Triggers.subscribe!
end
