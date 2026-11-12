require "test_helper"

# Request-size and rate limits for screenshot uploads (config/initializers/rack_attack.rb), checked on the Rack app itself
# so no body has to be built: the size rule looks at the Content-Length header before anything is read.
class ShipImagesLimitsTest < ActiveSupport::TestCase
  WINDOW_START = Time.utc(2030, 1, 1, 12, 0, 0)
  MULTIPART = "multipart/form-data; boundary=xyz".freeze

  setup do
    travel_to WINDOW_START
    Rack::Attack.enabled = true
    Rack::Attack.cache.store.clear
    @reached_app = 0
    @app = Rack::Attack.new(->(_env) { @reached_app += 1; [ 200, { "content-type" => "text/plain" }, [ "ok" ] ] })
    @limits = ShipImages::Config.current
  end

  teardown do
    Rack::Attack.cache.store.clear
    Rack::Attack.enabled = false
    travel_back
  end

  def call(path, method: "POST", length: 100, type: MULTIPART, ip: "203.0.113.20")
    env = Rack::MockRequest.env_for(path, method: method, "CONTENT_TYPE" => type, "REMOTE_ADDR" => ip, input: "")
    env["CONTENT_LENGTH"] = length.to_s
    @app.call(env).first
  end

  test "the whole request may carry every slot full plus a little text" do
    assert_equal 3 * 5_000_000 + 1.megabyte, @limits.max_request_bytes
  end

  test "an upload over the request limit is a 413 and never reaches the app" do
    over = @limits.max_request_bytes + 1
    assert_equal 413, call("/projects/5/ships", length: over)
    assert_equal 413, call("/ships/5", method: "PATCH", length: over)
    assert_equal 413, call("/ships/5", method: "PUT", length: over)
    assert_equal 0, @reached_app
  end

  test "the 413 explains the limits in words" do
    env = Rack::MockRequest.env_for("/projects/5/ships", method: "POST", "CONTENT_TYPE" => MULTIPART, "CONTENT_LENGTH" => (@limits.max_request_bytes + 1).to_s, input: "")
    _status, _headers, body = @app.call(env)
    assert_match(/Each screenshot can be up to 5\.0 MB and a ship can have 3/, body.each.to_a.join)
  end

  test "a request at the limit, a small one, a different path or a non-multipart body is not blocked" do
    assert_equal 200, call("/projects/5/ships", length: @limits.max_request_bytes)
    assert_equal 200, call("/projects/5/ships", length: 300)
    assert_equal 200, call("/ships/5", method: "GET", length: @limits.max_request_bytes + 1, ip: "203.0.113.21")
    assert_equal 200, call("/shop/orders", length: @limits.max_request_bytes + 1, ip: "203.0.113.22")
    assert_equal 200, call("/projects/5/ships", length: @limits.max_request_bytes + 1, type: "application/x-www-form-urlencoded", ip: "203.0.113.23")
  end

  test "uploads are limited per address and the limit comes from the config" do
    limit = @limits.uploads_per_10_minutes
    limit.times { assert_equal 200, call("/projects/5/ships") }
    assert_equal 429, call("/projects/5/ships")
    assert_equal 429, call("/ships/5", method: "PATCH")
    assert_equal 200, call("/projects/5/ships", ip: "203.0.113.99"), "another address has its own allowance"
    assert_equal 200, call("/ships/5", method: "GET"), "reading is not an upload"
  end
end
