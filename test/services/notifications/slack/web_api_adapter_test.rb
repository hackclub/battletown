require "test_helper"
require_relative "../../../support/notifications_helper"

class Notifications::Slack::WebApiAdapterTest < ActiveSupport::TestCase
  include NotificationsHelper

  SLACK_ID = "U0SECRET99".freeze
  TEXT = "A very private reminder text".freeze

  def adapter(**options) = Notifications::Slack::WebApiAdapter.new(token: TOKEN, **options)

  def deliver(response: nil, error: nil, **options)
    result = nil
    stub_http(response: response, error: error) { result = adapter(**options).deliver_dm(slack_id: SLACK_ID, text: TEXT) }
    result
  end

  test "posts JSON to chat.postMessage over HTTPS with a bearer token and 5 second timeouts" do
    stub_http(response: json_response({ ok: true })) do |seen|
      result = adapter.deliver_dm(slack_id: SLACK_ID, text: TEXT)
      assert result.ok?
      assert_not result.retryable

      start = seen[:starts].sole
      assert_equal "slack.com", start[:host]
      assert_equal 443, start[:port]
      assert_equal true, start[:options][:use_ssl]
      assert_equal 5, start[:options][:open_timeout]
      assert_equal 5, start[:options][:read_timeout]
      assert_equal 5, start[:options][:write_timeout]

      request = seen[:http].requests.sole
      assert_equal "/api/chat.postMessage", request.path
      assert_equal "Bearer #{TOKEN}", request["Authorization"]
      assert_match %r{\Aapplication/json}, request["Content-Type"]
      body = JSON.parse(request.body)
      assert_equal SLACK_ID, body["channel"]
      assert_equal TEXT, body["text"]
    end
  end

  test "refuses a non-HTTPS endpoint" do
    assert_raises(ArgumentError) { Notifications::Slack::WebApiAdapter.new(token: TOKEN, endpoint: "http://slack.com/api/chat.postMessage") }
  end

  test "reads the token from SLACK_BOT_TOKEN when none is given" do
    with_env("SLACK_BOT_TOKEN" => TOKEN) do
      stub_http(response: json_response({ ok: true })) do |seen|
        assert Notifications::Slack::WebApiAdapter.new.deliver_dm(slack_id: SLACK_ID, text: TEXT).ok?
        assert_equal "Bearer #{TOKEN}", seen[:http].requests.sole["Authorization"]
      end
    end
  end

  test "no token means a systemic permanent failure and no request" do
    with_env("SLACK_BOT_TOKEN" => nil) do
      stub_http(response: json_response({ ok: true })) do |seen|
        result = Notifications::Slack::WebApiAdapter.new.deliver_dm(slack_id: SLACK_ID, text: TEXT)
        assert_equal "missing_token", result.error_code
        assert result.systemic
        assert_not result.retryable
        assert_empty seen[:starts]
      end
    end
  end

  test "a blank recipient is a permanent failure without a request" do
    stub_http(response: json_response({ ok: true })) do |seen|
      result = adapter.deliver_dm(slack_id: "", text: TEXT)
      assert_equal "missing_recipient", result.error_code
      assert_empty seen[:starts]
    end
  end

  test "429 is retryable and honours Retry-After, clamped" do
    result = deliver(response: json_response({ ok: false, error: "ratelimited" }, code: "429", headers: { "retry-after" => "7" }))
    assert_not result.ok?
    assert result.retryable
    assert_equal "ratelimited", result.error_code
    assert_equal 7, result.retry_after

    assert_equal 30, deliver(response: json_response("", code: "429")).retry_after
    assert_equal 3600, deliver(response: json_response("", code: "429", headers: { "retry-after" => "999999" })).retry_after
    assert_equal 30, deliver(response: json_response("", code: "429", headers: { "retry-after" => "-5" })).retry_after
  end

  test "ok false errors map to retryable, permanent and systemic" do
    {
      "ratelimited" => [ true, false ], "internal_error" => [ true, false ], "service_unavailable" => [ true, false ],
      "channel_not_found" => [ false, false ], "user_not_found" => [ false, false ], "user_disabled" => [ false, false ],
      "cannot_dm_bot" => [ false, false ], "msg_too_long" => [ false, false ], "something_new" => [ false, false ],
      "invalid_auth" => [ false, true ], "token_revoked" => [ false, true ], "account_inactive" => [ false, true ],
      "not_authed" => [ false, true ], "missing_scope" => [ false, true ]
    }.each do |code, (retryable, systemic)|
      result = deliver(response: json_response({ ok: false, error: code }))
      assert_not result.ok?, code
      assert_equal code, result.error_code, code
      assert_equal retryable, result.retryable, "#{code} retryable"
      assert_equal systemic, result.systemic.present?, "#{code} systemic"
    end
  end

  test "an error code that is not a short snake case token is never copied" do
    [ "Bad Thing xoxb-LEAK", "x" * 41, "", nil, 42, "../etc" ].each do |hostile|
      result = deliver(response: json_response({ ok: false, error: hostile }))
      assert_equal "unknown_error", result.error_code
      assert_not_includes result.inspect, "LEAK"
    end
  end

  test "server errors are retryable and other statuses are permanent" do
    assert deliver(response: json_response("oops", code: "503")).retryable
    assert_equal "http_error", deliver(response: json_response("oops", code: "500")).error_code
    result = deliver(response: json_response("nope", code: "404"))
    assert_not result.retryable
    assert_equal "http_error", result.error_code
  end

  test "unparseable or unexpected bodies are retryable bad_response" do
    [ "<html>gateway</html>", "[1,2]", "null", "" ].each do |body|
      result = deliver(response: json_response(body))
      assert_equal "bad_response", result.error_code, body
      assert result.retryable
    end
  end

  test "network failures are retryable and never carry the exception message or token" do
    [ Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Errno::ECONNREFUSED, Errno::ECONNRESET, SocketError,
      OpenSSL::SSL::SSLError, EOFError, IOError ].each do |klass|
      result = deliver(error: klass.new("connecting with #{TOKEN} to #{SLACK_ID}"))
      assert_equal "network_error", result.error_code, klass.name
      assert result.retryable
      assert_not_includes result.inspect, TOKEN
      assert_not_includes result.inspect, SLACK_ID
    end
  end

  test "the token, Slack id and text never appear in logs, whatever happens" do
    logs = capture_logs do
      deliver(response: json_response({ ok: true }))
      deliver(response: json_response({ ok: false, error: "invalid_auth" }))
      deliver(response: json_response("garbage", code: "502"))
      deliver(error: Net::ReadTimeout.new("boom #{TOKEN}"))
    end
    [ TOKEN, SLACK_ID, TEXT ].each { |secret| assert_not_includes logs, secret }
  end

  test "delivers? is true for the real adapter" do
    assert adapter.delivers?
  end
end
