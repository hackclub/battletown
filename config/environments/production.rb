require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Hackatime tokens are encrypted at rest (HackatimeConnection). Fail loudly at boot rather than at the first
  # connection. The asset build (SECRET_KEY_BASE_DUMMY) has no environment, so it is exempt.
  unless ENV["SECRET_KEY_BASE_DUMMY"].present?
    missing = %w[ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY
                 ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT].select { |name| ENV[name].blank? }
    raise "Missing environment variables: #{missing.join(", ")} (Active Record encryption keys, see docs/DEPLOY.md)" if missing.any?
  end

  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = true

  # Skip http-to-https redirect for the health check endpoint, so a load balancer probing over plain HTTP
  # gets a 200 and not a 301. (assume_ssl already makes proxied requests look secure; this covers probes
  # that bypass it.)
  config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Shared, durable cache in PostgreSQL (Solid Cache; options in config/cache.yml, table from
  # db/cache_migrate). Rack::Attack counters use it too (config/initializers/rack_attack.rb).
  config.cache_store = :solid_cache_store

  # Active Job keeps its default in-process :async adapter: the app defines no jobs yet, and Solid Queue
  # has no database configured (see config/database.yml and the SOLID_QUEUE_IN_PUMA note in config/puma.rb).
  # config.active_job.queue_adapter = :solid_queue

  # Email (Notifications::Email, behind the Flipper flag `email`). SMTP only when the environment describes a complete
  # transport (SMTP_ADDRESS and MAIL_FROM, see config/email_transport.rb and docs/DEPLOY.md). Without it Rails would
  # try localhost:25, so the :test method is used with deliveries switched off (nothing is kept in memory or sent),
  # and the email dispatcher refuses to mark anything as sent.
  if (smtp = EmailTransport.smtp_settings)
    config.action_mailer.delivery_method = :smtp
    config.action_mailer.smtp_settings = smtp
    config.action_mailer.perform_deliveries = true
    config.action_mailer.raise_delivery_errors = true
  else
    config.action_mailer.delivery_method = :test
    config.action_mailer.perform_deliveries = false
  end

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Host header allowlist (DNS rebinding / host-header poisoning). Fails closed: without APP_HOST
  # (comma-separated hostnames) it falls back to the host of APP_URL instead of allowing any host.
  config.hosts = (ENV["APP_HOST"].presence || URI(ENV.fetch("APP_URL", "http://localhost:3000")).host.to_s).split(",").map(&:strip)
  # The load balancer probe on /up carries an arbitrary Host header, so it is exempt.
  config.host_authorization = { exclude: ->(request) { request.path == "/up" } }

  # Host used by links generated in mailer templates (the first allowed host).
  config.action_mailer.default_url_options = { host: config.hosts.first, protocol: "https" }
end
