require "test_helper"
require_relative "../../support/fake_hca"
require_relative "../../support/hackatime_helper"

# Hca::Me (GET /api/v1/me), Hca::Http and Hca::TokenRevoker against a fake over a real socket. The token and the provider's words
# never reach a log or an error message.
class Hca::MeTest < ActiveSupport::TestCase
  include HackatimeHelper # capture_logs, as_production

  setup do
    @fake = FakeHca.new(sub: "ident!example")
    @http = Hca::Http.new(base_url: @fake.url)
  end

  teardown { @fake.stop }

  def addresses(token = FakeHca::ACCESS_TOKEN) = Hca::Me.addresses(token, http: @http)

  def failure_code
    yield
    nil
  rescue Hca::LookupError => error
    error.code
  end

  # Hack Club Auth (or something pretending to be it) answering with something that is not HTTP: a clean lookup error, not a 500.
  test "a response that is not valid HTTP is a bad_response, not an exception" do
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      client = server.accept
      client.readpartial(4096)
      client.write("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nBad Header Without Colon\r\n\r\nhello")
      client.close
    rescue StandardError
      nil
    end
    http = Hca::Http.new(base_url: "http://127.0.0.1:#{server.addr[1]}")
    assert_equal :bad_response, failure_code { Hca::Me.addresses(FakeHca::ACCESS_TOKEN, http: http) }
  ensure
    thread&.kill
    server&.close
  end

  test "reads only identity.addresses, with the primary first, and sends the bearer token" do
    @fake.me = [ 200, { "identity" => { "id" => "ident!x", "primary_email" => "kid@example.test", "birthday" => "2010-01-01",
                                        "addresses" => [ FakeHca.address("addr_b"), FakeHca.address("addr_a", primary: true) ] },
                        "scopes" => %w[openid address] } ]
    result = addresses
    assert_equal %w[addr_a addr_b], result.addresses.map(&:id)
    assert_equal 0, result.skipped
    assert_equal "Bearer #{FakeHca::ACCESS_TOKEN}", @fake.requests_for("GET", "/api/v1/me").first.headers["authorization"]
    assert_equal "application/json", @fake.requests_for("GET", "/api/v1/me").first.headers["accept"]
    first = result.addresses.first
    assert_equal [ "Pat Example", "Exampleville", "US", "+15555550123", true ], [ first.recipient_name, first.city, first.country, first.phone_number, first.primary ]
    assert_equal %i[id recipient_name line_1 line_2 city state postal_code country phone_number primary], Hca::Address.members, "nothing else is ever kept"
  end

  test "an address without line 2 or last name is fine; a missing first name, street, city or country is skipped and counted" do
    @fake.me_with(FakeHca.address("addr_ok", "last_name" => nil, "line_2" => nil), FakeHca.address("addr_a", "first_name" => nil, "last_name" => nil),
                  FakeHca.address("addr_b", "line_1" => ""), FakeHca.address("addr_c", "city" => nil), FakeHca.address("addr_d", "country" => nil))
    result = addresses
    assert_equal %w[addr_ok], result.addresses.map(&:id)
    assert_equal "Pat", result.addresses.first.recipient_name
    assert_equal 4, result.skipped
  end

  test "an address with an odd id is skipped" do
    @fake.me_with(FakeHca.address("addr_ok"), FakeHca.address("<script>"), FakeHca.address(""))
    assert_equal %w[addr_ok], addresses.addresses.map(&:id)
  end

  test "more than twenty addresses are cut off" do
    @fake.me_with(*(1..25).map { |n| FakeHca.address("addr_#{n}") })
    result = addresses
    assert_equal 20, result.addresses.size
    assert_equal 5, result.skipped
  end

  test "no addresses key with the scope granted is simply none; without the scope it is not available" do
    @fake.me = [ 200, { "identity" => { "id" => "x" }, "scopes" => %w[openid address] } ]
    assert_empty addresses.addresses
    @fake.me = [ 200, { "identity" => { "id" => "x" } } ]
    assert_empty addresses.addresses
    @fake.me = [ 200, { "identity" => { "id" => "x" }, "scopes" => %w[openid] } ]
    assert_equal :not_available, failure_code { addresses }
  end

  test "every error status maps to a code" do
    {
      401 => :unauthorized, 403 => :not_available, 404 => :not_available, 429 => :unavailable, 500 => :unavailable, 502 => :unavailable,
      503 => :unavailable, 504 => :unavailable, 400 => :bad_response, 418 => :bad_response, 204 => :bad_response
    }.each do |status, code|
      @fake.me = [ status, status == 204 ? "" : { "x" => 1 } ]
      assert_equal code, failure_code { addresses }, "HTTP #{status}"
    end
  end

  test "bad bodies map to bad_response" do
    [ "not json", "[]", "null", "{\"identity\":1}", "{\"identity\":{\"addresses\":\"nope\"}}", "\xFF\xFE".b ].each do |body|
      @fake.me = [ 200, body ]
      assert_equal :bad_response, failure_code { addresses }, body.inspect
    end
  end

  test "a body over the cap is cut off and refused" do
    @fake.me = [ 200, "x" * 5000 ]
    small = Hca::Http.new(base_url: @fake.url, max_bytes: 1000)
    assert_equal :bad_response, failure_code { Hca::Me.addresses(FakeHca::ACCESS_TOKEN, http: small) }
  end

  test "a redirect is never followed" do
    @fake.me = [ 302, "", { "Location" => "#{@fake.url}/api/v1/elsewhere" } ]
    @fake.on("GET", "/api/v1/elsewhere") { |_req| [ 200, { "identity" => { "addresses" => [ FakeHca.address("addr_x") ] } } ] }
    assert_equal :bad_response, failure_code { addresses }
    assert_empty @fake.requests_for("GET", "/api/v1/elsewhere")
  end

  test "a slow answer times out, and so does a refused connection" do
    @fake.on("GET", "/api/v1/me") { |_req| sleep(0.5); [ 200, {} ] }
    assert_equal :unavailable, failure_code { Hca::Me.addresses(FakeHca::ACCESS_TOKEN, http: Hca::Http.new(base_url: @fake.url, read_timeout: 0.1)) }
    @fake.stop
    assert_equal :unavailable, failure_code { addresses }
  end

  test "the default timeouts are 5 seconds to connect and 10 to read" do
    assert_equal 5, Hca::Http::OPEN_TIMEOUT
    assert_equal 10, Hca::Http::READ_TIMEOUT
  end

  test "an empty or missing token is refused without a request" do
    [ nil, "" ].each { |token| assert_equal :unauthorized, failure_code { addresses(token) } }
    assert_empty @fake.requests
  end

  test "production only talks to Hack Club Auth over https" do
    as_production do
      assert_equal :bad_response, failure_code { addresses }
    end
    assert_empty @fake.requests
  end

  test "errors, logs and inspect output never carry the token or the provider's words" do
    @fake.me = [ 500, "boom #{FakeHca::ACCESS_TOKEN} Example Street" ]
    error = nil
    logs = capture_logs { error = (addresses rescue $!) } # rubocop:disable Style/RescueModifier
    assert_instance_of Hca::LookupError, error
    assert_equal "unavailable", error.message
    [ FakeHca::ACCESS_TOKEN, "Example Street" ].each do |secret|
      assert_not_includes logs, secret
      assert_not_includes error.inspect, secret
      assert_not_includes error.backtrace.join, secret
    end
  end

  # --- revoking ---

  test "the revoker posts each token with the app's credentials and reports how many were acknowledged" do
    assert_equal 2, Hca::TokenRevoker.call(FakeHca::ACCESS_TOKEN, FakeHca::REFRESH_TOKEN, nil, "", http: @http)
    assert_equal [ FakeHca::ACCESS_TOKEN, FakeHca::REFRESH_TOKEN ], @fake.revoked_tokens
    request = @fake.requests_for("POST", "/oauth/revoke").first
    assert_equal [ "test-hca-client-id", "test-hca-client-secret" ], request.form.values_at("client_id", "client_secret")
  end

  test "the revoker never raises: an error status, a dead server, or no credentials" do
    @fake.on("POST", "/oauth/revoke") { |_req| [ 500, "no" ] }
    assert_equal 0, Hca::TokenRevoker.call(FakeHca::ACCESS_TOKEN, http: @http)
    @fake.stop
    assert_equal 0, Hca::TokenRevoker.call(FakeHca::ACCESS_TOKEN, http: @http)
    original = Rails.configuration.x.hca.client_id
    Rails.configuration.x.hca.client_id = nil
    assert_equal 0, Hca::TokenRevoker.call(FakeHca::ACCESS_TOKEN, http: @http)
  ensure
    Rails.configuration.x.hca.client_id = original
  end

  test "the revoker stops starting new calls once its time budget is spent" do
    calls = 0
    slow = Object.new
    slow.define_singleton_method(:post_form) do |*|
      calls += 1
      sleep 0.15
      Hca::Http::Response.new(status: 200, body: "")
    end
    original = Hca::TokenRevoker::BUDGET
    Hca::TokenRevoker.send(:remove_const, :BUDGET)
    Hca::TokenRevoker.const_set(:BUDGET, 0.2)
    begin
      Hca::TokenRevoker.call("a", "b", "c", "d", http: slow)
    ensure
      Hca::TokenRevoker.send(:remove_const, :BUDGET)
      Hca::TokenRevoker.const_set(:BUDGET, original)
    end
    assert_operator calls, :<, 4
  end
end
