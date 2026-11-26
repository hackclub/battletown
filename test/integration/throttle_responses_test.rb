require "test_helper"

# The per-address limits sized for classrooms, the static files that do not use them up, and what a throttled visitor sees.
class ThrottleResponsesTest < ActionDispatch::IntegrationTest
  # Throttle keys are Time.now.to_i / period: start at a minute (and five-minute) boundary so no test straddles a window.
  WINDOW_START = Time.utc(2030, 1, 1, 12, 0, 0)
  IP = { "REMOTE_ADDR" => "203.0.113.70" }.freeze

  setup do
    travel_to WINDOW_START
    Rack::Attack.enabled = true
    Rack::Attack.cache.store.clear
  end

  teardown do
    Rack::Attack.cache.store.clear
    Rack::Attack.enabled = false
    travel_back
  end

  # Writes a throttle's counter directly, so the limit can be tested without sending thousands of requests.
  def fill(name, ip, count, period)
    Rack::Attack.cache.store.write("rack::attack:#{Time.now.to_i / period}:#{name}:#{ip}", count, expires_in: period)
  end

  test "the general limit is 1500 a 5 minutes per address and the sign-in limit 60 a minute" do
    assert_equal [ 1500, 5.minutes ], Rack::Attack.throttles["req/ip"].then { |t| [ t.limit, t.period ] }
    assert_equal [ 60, 1.minute ], Rack::Attack.throttles["auth/ip"].then { |t| [ t.limit, t.period ] }
  end

  test "the security-critical limits were not loosened" do
    limits = Rack::Attack.throttles.transform_values { |t| t.limit.respond_to?(:call) ? :configured : t.limit }
    {
      "admin_project_reviews/ip" => 30, "admin_users_write/ip" => 30, "admin_users_read/ip" => 120, "admin-shop/ip" => 60,
      "admin-bosses/ip" => 60, "admin_writes/ip" => 120, "privacy/ip" => 120, "hackatime/ip" => 20, "address_callback/ip" => 20,
      "email_unsubscribe/ip" => 20, "team/ip" => 30, "ship-images/ip" => :configured, "orders/user" => :configured,
      "address_lookup/user" => :configured, "admin_address_reveals/user" => :configured
    }.each { |name, limit| assert_equal limit, limits[name], name }
  end

  test "pictures and assets do not use up the general per-address limit" do
    counter = -> { Rack::Attack.cache.store.read("rack::attack:#{Time.now.to_i / 300}:req/ip:#{IP['REMOTE_ADDR']}").to_i }
    [ "/assets/app-abc.css", "/bosses/1/art", "/shop/items/sticker/image", "/Bosses//1/ART", "/bosses/%31/art" ].each do |path|
      get path, headers: IP
      head path, headers: IP
    end
    assert_equal 0, counter.call, "none of those counted"
    get "/", headers: IP
    assert_equal 1, counter.call, "a page does"
  end

  test "only GET and HEAD of the exact picture paths are exempt" do
    fill("req/ip", IP["REMOTE_ADDR"], 1500, 5.minutes)
    [ [ :post, "/bosses/1/art" ], [ :get, "/bosses/1/art/extra" ], [ :get, "/shop/items/sticker/images" ], [ :get, "/shop/items/sticker" ] ].each do |verb, path|
      send(verb, path, headers: IP)
      assert_response :too_many_requests, "#{verb.upcase} #{path} still counts"
    end
    get "/bosses/1/art", headers: IP
    assert_not_equal 429, response.status, "while the picture itself is let through"
  end

  test "boss and shop pictures keep a far larger limit of their own, assets have none" do
    fill("media/ip", "203.0.113.71", 6000, 5.minutes)
    get "/bosses/1/art", headers: { "REMOTE_ADDR" => "203.0.113.71" }
    assert_response :too_many_requests
    get "/shop/items/sticker/image", headers: { "REMOTE_ADDR" => "203.0.113.71" }
    assert_response :too_many_requests
    get "/assets/app-abc.css", headers: { "REMOTE_ADDR" => "203.0.113.71" }
    assert_not_equal 429, response.status
    get "/", headers: { "REMOTE_ADDR" => "203.0.113.71" }
    assert_response :success, "pages are a separate bucket"
  end

  test "a throttled page is a friendly HTML page with Retry-After" do
    fill("req/ip", "203.0.113.72", 1500, 5.minutes)
    travel_to WINDOW_START + 100.seconds
    get "/", headers: { "REMOTE_ADDR" => "203.0.113.72", "Accept" => "text/html,application/xhtml+xml,*/*;q=0.8" }
    assert_response :too_many_requests
    assert_equal "200", response.headers["Retry-After"], "the rest of the 5-minute window"
    assert_match %r{\Atext/html}, response.media_type
    assert_equal "no-store", response.headers["Cache-Control"]
    page = Nokogiri::HTML5(response.body)
    assert_equal "Error 429", page.at("p.code").text
    assert_equal "Too many requests at once", page.at("h1").text
    assert_match(/Wait a minute or two/, page.at("main").text)
    assert page.at("a.cta[href='/']")
    assert_equal Rails.public_path.join("429.html").read, response.body
  end

  test "a throttled sign-in post gets the same page, with the one-minute window" do
    travel_to WINDOW_START + 20.seconds
    fill("auth/ip", IP["REMOTE_ADDR"], 60, 1.minute)
    post "/auth/hack_club", headers: IP
    assert_response :too_many_requests
    assert_equal "40", response.headers["Retry-After"]
    assert_includes response.body, "Too many requests at once"
  end

  test "a throttled JSON request gets JSON with Retry-After" do
    fill("req/ip", "203.0.113.73", 1500, 5.minutes)
    ip = { "REMOTE_ADDR" => "203.0.113.73" }
    travel_to WINDOW_START + 30.seconds

    get "/", headers: ip.merge("Accept" => "application/json")
    assert_response :too_many_requests
    assert_equal "270", response.headers["Retry-After"]
    assert_match %r{\Aapplication/json}, response.media_type
    body = response.parsed_body
    assert_equal "rate_limited", body["error"]
    assert_equal 270, body["retry_after"]
    assert_equal "Too many requests. Please wait 5 minutes and try again.", body["message"]

    get "/onboarding/age.json", headers: ip
    assert_equal "application/json", response.media_type
    post "/onboarding/age", params: {}, as: :json, headers: ip
    assert_equal "application/json", response.media_type
  end

  test "a throttled privacy API call is JSON too" do
    fill("privacy/ip", IP["REMOTE_ADDR"], 120, 1.minute)
    post "/api/privacy/delete", headers: IP
    assert_response :too_many_requests
    assert_equal "application/json", response.media_type
    assert_equal "60", response.headers["Retry-After"]
    assert_equal "a minute", response.parsed_body["message"][/a minute/]
  end

  test "a longer window reports minutes, never zero seconds" do
    request = Struct.new(:env, :path, :media_type) do
      def get_header(_name) = nil
    end
    at_end = request.new({ "rack.attack.match_data" => { period: 60, epoch_time: WINDOW_START.to_i + 59 } }, "/x", nil)
    assert_equal "1", Rack::Attack::ThrottledResponse.call(at_end)[1]["retry-after"]
    hour = request.new({ "rack.attack.match_data" => { period: 3600, epoch_time: WINDOW_START.to_i } }, "/api/x", nil)
    status, headers, body = Rack::Attack::ThrottledResponse.call(hour)
    assert_equal 429, status
    assert_equal "3600", headers["retry-after"]
    assert_includes body.first, "60 minutes"
    unknown = request.new({}, "/x", nil)
    assert_equal "60", Rack::Attack::ThrottledResponse.call(unknown)[1]["retry-after"]
  end
end
