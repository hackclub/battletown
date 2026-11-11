require "test_helper"

class TrustedProxiesTest < ActiveSupport::TestCase
  test "parses IPs and CIDRs separated by commas or spaces" do
    parsed = TrustedProxies.parse("203.0.113.0/24, 198.51.100.7  2001:db8::/32")
    assert_equal %w[203.0.113.0/24 198.51.100.7/32 2001:db8::/32], parsed.map { |ip| "#{ip}/#{ip.prefix}" }
  end

  test "ignores blanks, invalid entries and catch-all ranges, reporting each rejected entry" do
    rejected = []
    parsed = TrustedProxies.parse("bogus, , 10.0.0.1/99, 0.0.0.0/0, ::/0, example.com, 203.0.113.1") { |entry, _reason| rejected << entry }
    assert_equal [ IPAddr.new("203.0.113.1") ], parsed
    assert_equal %w[bogus 10.0.0.1/99 0.0.0.0/0 ::/0 example.com], rejected
  end

  test "nil and empty values yield nothing" do
    assert_empty TrustedProxies.parse(nil)
    assert_empty TrustedProxies.parse("")
  end

  test "rack-attack keys on the client address and skips trusted proxies, like request.remote_ip" do
    headers = { "REMOTE_ADDR" => "198.51.100.5", "HTTP_X_FORWARDED_FOR" => "192.0.2.1, 203.0.113.9, 198.51.100.5" }
    keyed = lambda do |proxies|
      seen = nil
      stack = ActionDispatch::RemoteIp.new(->(env) { seen = Rack::Attack::Request.new(env).ip; [ 200, {}, [ "" ] ] }, true, proxies)
      stack.call(Rack::MockRequest.env_for("/", headers))
      seen
    end

    default = ActionDispatch::RemoteIp::TRUSTED_PROXIES
    assert_equal "198.51.100.5", keyed.call(default)
    assert_equal "203.0.113.9", keyed.call(default + [ IPAddr.new("198.51.100.0/24") ])
  end

  test "a spoofing-looking request still gets an address instead of an error" do
    headers = { "REMOTE_ADDR" => "203.0.113.50", "HTTP_CLIENT_IP" => "192.0.2.1", "HTTP_X_FORWARDED_FOR" => "198.51.100.1" }
    seen = nil
    stack = ActionDispatch::RemoteIp.new(->(env) { seen = Rack::Attack::Request.new(env).ip; [ 200, {}, [ "" ] ] }, true, nil)
    stack.call(Rack::MockRequest.env_for("/", headers))
    assert_equal "203.0.113.50", seen
  end
end
