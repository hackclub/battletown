ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require_relative "support/features_helper"
require_relative "support/analytics_helper"
require_relative "support/stub_method"

Analytics::Views.ensure_current!

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)
    # The insights views are SQL, outside db/schema.rb: a schema load builds them, and this rebuilds them when the SQL file changed since (cheap otherwise).
    parallelize_setup { |_worker| Analytics::Views.ensure_current! }

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    include FeaturesHelper
    include AnalyticsHelper
    include StubMethod

    # Add more helper methods to be used by all tests here...
  end
end

# Throttle counters would leak across tests; the throttling test turns Rack::Attack back on explicitly.
Rack::Attack.enabled = false
