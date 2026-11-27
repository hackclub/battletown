require "test_helper"
require "open3"

# Boots the app in production mode in a subprocess to check settings that only exist there.
class ProductionConfigTest < ActiveSupport::TestCase
  def production_eval(code, env = {})
    full_env = { "RAILS_ENV" => "production", "SECRET_KEY_BASE_DUMMY" => "1", "APP_HOST" => nil, "APP_URL" => nil,
                 "DATABASE_URL" => nil, "CACHE_DATABASE_URL" => nil, "TRUSTED_PROXIES" => nil }.merge(env)
    out, status = Open3.capture2e(full_env, Rails.root.join("bin/rails").to_s, "runner", code, chdir: Rails.root.to_s)
    assert status.success?, out
    out.lines.last.to_s.strip
  end

  test "host allowlist falls back to the APP_URL host and never allows any host" do
    assert_equal '["battle.example"]', production_eval("p Rails.application.config.hosts", "APP_URL" => "https://battle.example")
    assert_equal '["a.example", "b.example"]', production_eval("p Rails.application.config.hosts", "APP_HOST" => "a.example, b.example")
    assert_equal '["localhost"]', production_eval("p Rails.application.config.hosts")
  end

  test "the health check is exempt from host authorization and the SSL redirect, and is not logged" do
    code = <<~RUBY
      call = ->(url) { Rails.application.call(Rack::MockRequest.env_for(url)).first }
      exclude = Rails.application.config.ssl_options[:redirect][:exclude]
      request = ->(path) { ActionDispatch::Request.new(Rack::MockRequest.env_for(path)) }
      p [call.("http://lb-probe.internal/up"), call.("http://lb-probe.internal/privacy"),
         exclude.call(request.("/up")), exclude.call(request.("/privacy")), Rails.application.config.silence_healthcheck_path]
    RUBY
    assert_equal '[200, 403, true, false, "/up"]', production_eval(code, "APP_URL" => "https://battle.example")
  end

  test "production caches in Solid Cache, and rack-attack shares it behind the fail-open wrapper" do
    code = "p [Rails.cache.class.name, Rack::Attack.cache.store.class.name]"
    assert_equal '["SolidCache::Store", "FailOpenCacheStore"]', production_eval(code)
  end

  test "a lone DATABASE_URL serves the cache connection too, CACHE_DATABASE_URL splits it" do
    code = <<~RUBY
      p ActiveRecord::Base.configurations.configs_for(env_name: "production").map { |c| [c.name, c.database, c.host] }
    RUBY
    assert_equal '[["primary", "app", "db.example"], ["cache", "app", "db.example"]]',
      production_eval(code, "DATABASE_URL" => "postgres://u:p@db.example/app")
    assert_equal '[["primary", "app", "db.example"], ["cache", "cache", "cache.example"]]',
      production_eval(code, "DATABASE_URL" => "postgres://u:p@db.example/app", "CACHE_DATABASE_URL" => "postgres://u:p@cache.example/cache")
  end

  test "an unreachable database does not break throttling or public pages" do
    code = <<~RUBY
      env = Rack::MockRequest.env_for("https://battle.example/privacy", "HTTP_HOST" => "battle.example", "REMOTE_ADDR" => "203.0.113.5")
      p [Rails.application.call(env).first, Rack::Attack.cache.count("probe", 60)]
    RUBY
    assert_equal "[200, 1]", production_eval(code, "APP_URL" => "https://battle.example", "DATABASE_URL" => "postgres://nobody@127.0.0.1:1/none")
  end

  test "TRUSTED_PROXIES makes request.remote_ip and the rack-attack IP skip the listed public proxy" do
    code = <<~RUBY
      env = Rack::MockRequest.env_for("https://battle.example/privacy", "HTTP_HOST" => "battle.example", "REMOTE_ADDR" => "198.51.100.5",
        "HTTP_X_FORWARDED_FOR" => "192.0.2.1, 203.0.113.9, 198.51.100.5")
      Rails.application.call(env)
      p [env["action_dispatch.remote_ip"].to_s, Rack::Attack::Request.new(env).ip]
    RUBY
    app_env = { "APP_URL" => "https://battle.example" }
    # Without the variable the public proxy address is the client, so every visitor would share a bucket.
    assert_equal '["198.51.100.5", "198.51.100.5"]', production_eval(code, app_env)
    assert_equal '["203.0.113.9", "203.0.113.9"]', production_eval(code, app_env.merge("TRUSTED_PROXIES" => "198.51.100.0/24"))
    assert_equal '["203.0.113.9", "203.0.113.9"]',
      production_eval(code, app_env.merge("TRUSTED_PROXIES" => "not-an-ip, 0.0.0.0/0, 198.51.100.5 ,300.1.1.1/8"))
  end

  test "production enforces SSL, secure cookies and rejects unknown hosts" do
    code = <<~RUBY
      app = Rails.application
      statuses = [["evil.example", "/privacy"], ["battle.example", "/privacy"]].map do |host, path|
        app.call(Rack::MockRequest.env_for("https://\#{host}\#{path}", "HTTP_HOST" => host)).first
      end
      p [Rails.application.config.force_ssl, Rails.application.config.session_options[:secure], statuses]
    RUBY
    assert_equal "[true, true, [403, 200]]", production_eval(code, "APP_URL" => "https://battle.example", "DATABASE_URL" => "postgres://localhost/battletown_test")
  end
end
