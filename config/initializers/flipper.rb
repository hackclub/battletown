# Feature flags (docs/CONTRACT.md, "Feature flags"). Flags live in the database (flipper_features, flipper_gates) and
# are flipped at /admin/flipper by admins; the code reads them through Features.enabled?. In tests Flipper uses its
# in-memory adapter (config.flipper.test_help, on in the test environment) and is reset before every test.
Rails.application.configure do
  # One database read per flag per request, not per check. No preloading: pages and health checks that use no flag
  # cost nothing.
  config.flipper.memoize = true
  config.flipper.preload = false
  # Flag checks stay out of the logs (an actor check would print a user id).
  config.flipper.log = false
  # Flipper's development-only "strict" mode warns about every flag it has not stored yet; every known flag is registered
  # at boot and an unstored flag simply means off, so the warnings (printed by db:migrate, db:seed, the console) are noise.
  config.flipper.strict = false
end

# The database adapter is required lazily, on first use. Requiring flipper-active_record from the Gemfile loads
# ActiveRecord::Base before config/initializers/filter_parameter_logging.rb has run, which would leave the
# parameter filters off the SQL log (test/integration/full_flow_log_privacy_test.rb catches that).
Flipper.configure do |config|
  config.adapter do
    require "flipper/adapters/active_record"
    Flipper::Adapters::ActiveRecord.new
  end
end

# Staff can dogfood a flag before it is on for everyone: Flipper.enable_group(:team, :admins). Per-user actor gates
# are discouraged: they store user ids in flipper_gates and are not removed when a user is deleted. Percentage gates
# are fine.
Flipper.register(:admins) { |actor| actor.respond_to?(:admin?) && actor.admin? }

# The UI is the only way to flip a flag, so keep it self-contained and quiet.
Flipper::UI.configure do |config|
  config.version_check_enabled = false # no call out to flippercloud.io
  config.cloud_recommendation = false
  config.fun = false
  config.application_href = "/admin"
  # The known flags are registered below; a flag made or deleted in the UI would only ever be a typo or a mistake.
  config.feature_creation_enabled = false
  config.feature_removal_enabled = false
end

# Make every known flag show up in the UI (off until enabled). Never during tests (memory adapter, reset per test),
# and safe when the tables or the database are missing: db:prepare, schema load and assets:precompile boot the app too.
Rails.application.config.after_initialize do
  Features.register_known! unless Rails.env.test?
end
