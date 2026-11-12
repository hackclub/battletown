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
    config.autoload_lib(ignore: %w[assets tasks omniauth])

    # Rails only emits the deprecated Feature-Policy header, so set Permissions-Policy directly.
    config.action_dispatch.default_headers["Permissions-Policy"] = "camera=(), microphone=(), geolocation=(), payment=(), usb=()"

    # Hack Club Auth (see config/initializers/omniauth.rb).
    config.x.hca.issuer = ENV.fetch("HCA_ISSUER", "https://auth.hackclub.com")
    config.x.hca.redirect_uri = "#{ENV.fetch("APP_URL", "http://localhost:3000")}/auth/hack_club/callback"

    # Hackatime account linking (config/initializers/omniauth.rb, docs/HACKATIME.md). The redirect URI must match
    # the one registered on the Hackatime OAuth app exactly. HACKATIME_URL exists so a local fake provider can stand in.
    config.x.hackatime.base_url = ENV.fetch("HACKATIME_URL", "https://hackatime.hackclub.com").chomp("/")
    config.x.hackatime.redirect_uri = "#{ENV.fetch("APP_URL", "http://localhost:3000")}/auth/hackatime/callback"
    config.x.hackatime.scopes = "profile read"
    # The OAuth app's credentials: environment first, Rails credentials as the fallback (like Hack Club Auth).
    config.x.hackatime.client_id = ENV["HACKATIME_CLIENT_ID"].presence
    config.x.hackatime.client_secret = ENV["HACKATIME_CLIENT_SECRET"].presence

    # Active Record encryption for the Hackatime tokens (HackatimeConnection). Keys come from the environment in every
    # environment except test (config/environments/test.rb); production refuses to boot without them (production.rb).
    # Generate values with `bin/rails db:encryption:init`.
    config.active_record.encryption.primary_key = ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"].presence
    config.active_record.encryption.deterministic_key = ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"].presence
    config.active_record.encryption.key_derivation_salt = ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"].presence

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
