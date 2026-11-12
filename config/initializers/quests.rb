# Subscribes quest payouts (app/services/quests/triggers.rb) to the ship-approved event. Runs once at boot, after the
# app is loaded; the subscriber block resolves the handler when an event fires, so code reloading keeps working and
# nothing is subscribed twice. The handler does nothing while the Flipper flag `quests` is off.
Rails.application.config.after_initialize do
  Quests::Triggers.subscribe!
end
