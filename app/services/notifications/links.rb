module Notifications
  # Absolute links for Slack messages, built on the app's public URL (APP_URL). Every DM that needs an answer links to
  # the web page that already handles it: the Slack app has chat:write only, so there are no buttons.
  module Links
    module_function

    def base = ENV.fetch("APP_URL", "http://localhost:3000").to_s.strip.chomp("/")

    def projects = absolute(routes.projects_path)

    def ship_form(project_id) = absolute(routes.new_project_ship_path(project_id))

    # The ship form pre-filled from a rejected ship, so a fix is one click away.
    def fix_ship(ship) = absolute(routes.new_project_ship_path(ship.project_id, from: ship.id))

    def ship(ship) = absolute(routes.ship_path(ship))

    def absolute(path) = "#{base}#{path}"
    def routes = Rails.application.routes.url_helpers
    private_class_method :absolute, :routes
  end
end
