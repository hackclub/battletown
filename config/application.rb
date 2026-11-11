require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Battletown
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Rails only emits the deprecated Feature-Policy header, so set Permissions-Policy directly.
    config.action_dispatch.default_headers["Permissions-Policy"] = "camera=(), microphone=(), geolocation=(), payment=(), usb=()"

    # Hack Club Auth (see config/initializers/omniauth.rb).
    config.x.hca.issuer = ENV.fetch("HCA_ISSUER", "https://auth.hackclub.com")
    config.x.hca.redirect_uri = "#{ENV.fetch("APP_URL", "http://localhost:3000")}/auth/hack_club/callback"

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
