require_relative "boot"
require_relative "email_transport"

require "rails"
# Only the frameworks the app uses. Active Storage, Action Mailbox and Action Text are left out on purpose: nothing
# uploads or receives email, and each of them would otherwise add public /rails/... endpoints.
%w[
  active_record/railtie
  active_job/railtie
  action_controller/railtie
  action_mailer/railtie
  action_view/railtie
  action_cable/engine
  rails/test_unit/railtie
].each { |railtie| require railtie }

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
    # "Who is this visitor?" (Hack Club Auth's browser whoami endpoint, called from the page itself: app/javascript/controllers/whoami_client.js).
    # It answers only for an origin an Auth admin has set as the app's `whoami_allowed_origin`, and only on a hackclub.com host, so it is OFF in
    # production until HCA_WHOAMI=1. In development and test it is on only when HCA_WHOAMI_STUB_URL names a stub (never read in production).
    whoami_stub = ENV["HCA_WHOAMI_STUB_URL"].presence unless Rails.env.production?
    config.x.hca.whoami_url = whoami_stub || "#{ENV.fetch("HCA_ISSUER", "https://auth.hackclub.com")}/api/external/whoami"
    config.x.hca.whoami_enabled = whoami_stub.present? || (Rails.env.production? && ENV["HCA_WHOAMI"] == "1")
    # The Hack Club Auth app's credentials (also used by the address lookup, which revokes its one-time token).
    config.x.hca.client_id = ENV["HCA_CLIENT_ID"].presence
    config.x.hca.client_secret = ENV["HCA_CLIENT_SECRET"].presence
    # Shipping-address lookup at checkout (projects/battletown/specs/contract.md, "Shipping addresses"): a second sign-in provider with only the
    # `openid address` scopes, its own callback (register this exact URI on the Hack Club Auth app), and the page where a
    # person adds or edits the addresses saved in Hack Club Auth.
    config.x.hca.address_redirect_uri = "#{ENV.fetch("APP_URL", "http://localhost:3000")}/auth/hack_club_address/callback"
    config.x.hca.address_scopes = %i[openid address]
    config.x.hca.address_portal_url = ENV.fetch("HCA_ADDRESS_PORTAL_URL", "#{ENV.fetch("HCA_ISSUER", "https://auth.hackclub.com")}/portal/address")

    # Hackatime account linking (config/initializers/omniauth.rb, projects/battletown/specs/hackatime.md). The redirect URI must match
    # the one registered on the Hackatime OAuth app exactly. HACKATIME_URL exists so a local fake provider can stand in.
    config.x.hackatime.base_url = ENV.fetch("HACKATIME_URL", "https://hackatime.hackclub.com").chomp("/")
    config.x.hackatime.redirect_uri = "#{ENV.fetch("APP_URL", "http://localhost:3000")}/auth/hackatime/callback"
    config.x.hackatime.scopes = "profile read"
    # The OAuth app's credentials: environment first, Rails credentials as the fallback (like Hack Club Auth).
    config.x.hackatime.client_id = ENV["HACKATIME_CLIENT_ID"].presence
    config.x.hackatime.client_secret = ENV["HACKATIME_CLIENT_SECRET"].presence
    # The sign-in chain (SessionsController#hackatime_step, like Save Point's): straight after Hack Club sign-in, someone
    # with no working Hackatime link is sent on to Hackatime's OAuth, which signs in with Hack Club too, so it usually passes
    # through with no screen. On when the OAuth app is set up; HACKATIME_CHAIN=0 turns it off (for example when the app's
    # credentials are not working yet, so sign-in does not send everyone into a failing step). Off in tests unless one sets it.
    config.x.hackatime.sign_in_chain = config.x.hackatime.client_id.present? && config.x.hackatime.client_secret.present? && ENV["HACKATIME_CHAIN"] != "0"

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
