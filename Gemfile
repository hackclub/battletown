source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1.4"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
# Use postgresql as the database for Active Record
gem "pg", "~> 1.1"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Use the database-backed adapters for Rails.cache, Active Job, and Action Cable
gem "solid_cache"
gem "solid_queue"
gem "solid_cable"

# Verifies the ES256 tokens Hack Club's data-deletion service sends (see docs/PRIVACY_API.md)
gem "jwt", "~> 3.2"

# Reads the Hackatime hours CSV for hours:import (csv is a bundled gem, not default, since Ruby 3.4)
gem "csv"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
gem "image_processing", "~> 2.2"

# The ship screenshot processor (app/services/ship_images/processor.rb) calls libvips directly. image_processing 1.x
# pulled this in; 2.x does not, so it is a direct dependency here and bumping image_processing cannot drop it. require: false
# keeps libvips (and the system libxml2 it can pull in) from loading before Nokogiri, whose XPath then breaks.
gem "ruby-vips", "~> 2.3", require: false

group :development, :test do
  # Load .env into ENV (never loaded in production; set real env vars there)
  gem "dotenv-rails"

  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"
end

group :test do
  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
  gem "capybara"
  gem "selenium-webdriver"
end

gem "omniauth"
gem "omniauth-rails_csrf_protection"
gem "omniauth_openid_connect"
gem "rack-attack"

gem "omniauth-oauth2", "~> 1.9"

# Feature flags: every new feature ships switched off until the owner flips it at /admin/flipper (see docs/CONTRACT.md)
gem "flipper", "~> 1.4"
gem "flipper-active_record", "~> 1.4", require: false # required lazily by config/initializers/flipper.rb
gem "flipper-ui", "~> 1.4"
