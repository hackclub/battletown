require "test_helper"
require "open3"

# Production must not boot without the Active Record encryption keys (the Hackatime tokens are encrypted with
# them) and must only talk to Hackatime over https.
class HackatimeProductionConfigTest < ActiveSupport::TestCase
  KEYS = {
    "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => "prod-like-primary-key-0000000000000",
    "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY" => "prod-like-deterministic-key-00000000",
    "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT" => "prod-like-key-derivation-salt-0000"
  }.freeze

  def boot_production(env = {})
    full_env = { "RAILS_ENV" => "production", "SECRET_KEY_BASE" => "k" * 64, "SECRET_KEY_BASE_DUMMY" => nil, "APP_HOST" => nil, "APP_URL" => nil,
                 "DATABASE_URL" => nil, "CACHE_DATABASE_URL" => nil, "HACKATIME_URL" => nil }.merge(KEYS).merge(env)
    Open3.capture2e(full_env, Rails.root.join("bin/rails").to_s, "runner", "puts :booted", chdir: Rails.root.to_s)
  end

  test "boot fails loudly, naming the variable, when an encryption key is missing" do
    KEYS.each_key do |name|
      out, status = boot_production(name => nil)
      assert_not status.success?, "booted without #{name}"
      assert_includes out, name
    end
  end

  test "boot succeeds with all three keys" do
    out, status = boot_production
    assert status.success?, out
    assert_includes out, "booted"
  end

  test "the asset build (SECRET_KEY_BASE_DUMMY) does not need the keys" do
    out, status = boot_production("SECRET_KEY_BASE_DUMMY" => "1", "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => nil)
    assert status.success?, out
  end

  test "production refuses a non-https Hackatime URL" do
    out, status = boot_production("HACKATIME_URL" => "http://hackatime.example")
    assert_not status.success?
    assert_includes out, "HACKATIME_URL must be an https URL"
  end
end
