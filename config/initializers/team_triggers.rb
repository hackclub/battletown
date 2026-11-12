# Subscribes the crew bonus (app/services/teams/triggers.rb) to the ship approval event. Runs once at boot, after the app is
# loaded; the subscriber block resolves the handler when an event fires, so code reloading keeps working and nothing is
# subscribed twice. The handler checks the `team` flag every time: while it is off it does nothing at all.
Rails.application.config.after_initialize do
  Teams::Triggers.subscribe!
end
