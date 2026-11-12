# Sends due notifications. Schedule it every minute or so (cron: `bin/rails notifications:dispatch`, or Solid Queue
# recurring tasks). It does nothing unless NOTIFICATIONS_ENABLED=true (see Notifications::Dispatcher); the email rows go the same way (Notifications::Email::Dispatcher).
class DispatchNotificationsJob < ApplicationJob
  queue_as :default

  def perform
    Notifications::Dispatcher.run
    Notifications::Email::Dispatcher.run # a no-op while the Flipper flag `email` is off
  end
end
