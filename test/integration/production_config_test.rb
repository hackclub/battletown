require "test_helper"
require "open3"

# Boots the app in production mode in a subprocess to check settings that only exist there.
class ProductionConfigTest < ActiveSupport::TestCase
  def production_eval(code, env = {})
    full_env = { "RAILS_ENV" => "production", "SECRET_KEY_BASE_DUMMY" => "1", "APP_HOST" => nil, "APP_URL" => nil }.merge(env)
    out, status = Open3.capture2e(full_env, Rails.root.join("bin/rails").to_s, "runner", code, chdir: Rails.root.to_s)
    assert status.success?, out
    out.lines.last.to_s.strip
  end

  test "host allowlist falls back to the APP_URL host and never allows any host" do
    assert_equal '["battle.example"]', production_eval("p Rails.application.config.hosts", "APP_URL" => "https://battle.example")
    assert_equal '["a.example", "b.example"]', production_eval("p Rails.application.config.hosts", "APP_HOST" => "a.example, b.example")
    assert_equal '["localhost"]', production_eval("p Rails.application.config.hosts")
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
