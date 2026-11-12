module Admin
  # /admin/email: how many email rows there are per week and status (Notifications::Email::Stats). Aggregates only, no
  # addresses or names. Admins only (BaseController), and the route exists only while the Flipper flag `email` is on.
  class EmailNotificationsController < BaseController
    before_action { require_feature!(:email) }

    def show
      @weeks = Notifications::Email::Stats.weekly
      @statuses = Notification::STATUSES
      @transport = Notifications::Email.adapter.delivers? ? "SMTP configured" : "No real transport (nothing is sent)"
      @dispatching = Notifications::Dispatcher.enabled?
    end
  end
end
