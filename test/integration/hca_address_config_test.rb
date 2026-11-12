require "test_helper"
require "open3"

# The address lookup's configuration: the second provider and its callback URI, and the rule that production only talks to Hack Club
# Auth over https (the one-time token travels to it).
class HcaAddressConfigTest < ActiveSupport::TestCase
  KEYS = {
    "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => "prod-like-primary-key-0000000000000",
    "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY" => "prod-like-deterministic-key-00000000",
    "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT" => "prod-like-key-derivation-salt-0000"
  }.freeze

  def boot_production(env = {})
    full_env = { "RAILS_ENV" => "production", "SECRET_KEY_BASE" => "k" * 64, "SECRET_KEY_BASE_DUMMY" => nil, "APP_HOST" => nil, "APP_URL" => nil,
                 "DATABASE_URL" => nil, "CACHE_DATABASE_URL" => nil, "HACKATIME_URL" => nil, "HCA_ISSUER" => nil }.merge(KEYS).merge(env)
    Open3.capture2e(full_env, Rails.root.join("bin/rails").to_s, "runner", "puts :booted", chdir: Rails.root.to_s)
  end

  test "production refuses an http Hack Club Auth issuer" do
    out, status = boot_production("HCA_ISSUER" => "http://auth.example")
    assert_not status.success?
    assert_includes out, "HCA_ISSUER must be an https URL"
  end

  test "production boots with the default issuer" do
    out, status = boot_production
    assert status.success?, out
  end

  test "the address provider is registered alongside sign-in, with only the openid and address scopes and its own callback" do
    assert_equal %i[openid address], Rails.configuration.x.hca.address_scopes
    assert_equal "http://localhost:3000/auth/hack_club_address/callback", Rails.configuration.x.hca.address_redirect_uri
    assert_equal "hack_club_address", OmniAuth::Strategies::HackClubAddress.default_options.name
  end

  test "sign-in asks only for what it uses: the address scope stays (time zone default), phone and birthdate are not requested" do
    source = Rails.root.join("config/initializers/omniauth.rb").read
    assert_includes source, "scope: %i[openid profile email name address verification_status slack_id basic_info]"
    assert_no_match(/scope: %i\[[^\]]*(phone|birthdate)/, source)
  end

  test "the callback path is routed to the address controller only, and the sign-in callback does not accept the new provider" do
    assert_equal({ controller: "address_callbacks", action: "create" }, Rails.application.routes.recognize_path("/auth/hack_club_address/callback"))
    assert_equal({ controller: "sessions", action: "create", provider: "hack_club" }, Rails.application.routes.recognize_path("/auth/hack_club/callback"))
  end

  test "no Hack Club Auth token has a column anywhere: only the Hackatime connection stores tokens" do
    token_columns = ActiveRecord::Base.connection.tables.flat_map do |table|
      ActiveRecord::Base.connection.columns(table).map(&:name).grep(/token/).map { |column| "#{table}.#{column}" }
    end
    assert_equal %w[hackatime_connections.access_token hackatime_connections.refresh_token], (token_columns - %w[teams.invite_token]).sort # a crew invite is not a Hack Club Auth token
  end
end
