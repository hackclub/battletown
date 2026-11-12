module Notifications
  # Absolute links for Slack messages, built on the app's public URL (APP_URL). Every DM that needs an answer links to
  # the web page that already handles it: the Slack app has chat:write only, so there are no buttons.
  module Links
    module_function

    def base = ENV.fetch("APP_URL", "http://localhost:3000").to_s.strip.chomp("/")

    def projects = absolute(routes.projects_path)

    def dashboard = absolute(routes.dashboard_path)

    def ship_form(project_id) = absolute(routes.new_project_ship_path(project_id))

    # The ship form pre-filled from a rejected ship, so a fix is one click away.
    def fix_ship(ship) = absolute(routes.new_project_ship_path(ship.project_id, from: ship.id))

    def ship(ship) = absolute(routes.ship_path(ship))

    # The buyer's own order page (the only place a tracking number is shown; it never goes in a message).
    def order(order) = absolute(routes.order_path(order))

    # The one-click survey page (no login). The token is made by Nps::Token at send time.
    def feedback(token) = absolute(routes.feedback_path(token: token))

    # Email only: the notification settings and the signed unsubscribe page (GET shows it, POST acts).
    def settings = absolute(routes.settings_notifications_path)

    def email_unsubscribe(token) = absolute(routes.email_unsubscribe_path(token: token))

    def absolute(path) = "#{base}#{path}"
    def routes = Rails.application.routes.url_helpers
    private_class_method :absolute, :routes
  end
end
