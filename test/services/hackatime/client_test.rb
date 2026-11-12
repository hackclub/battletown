require "test_helper"
require_relative "../../support/hackatime_helper"

module Hackatime
  class ClientTest < ActiveSupport::TestCase
    include HackatimeHelper

    setup do
      @fake = start_fake_hackatime
      @user = users(:onboarded)
    end

    teardown { stop_fake_hackatime }

    def client_for(connection, **options) = Client.new(connection, base_url: @fake.url, client_id: "cid", client_secret: "csecret", **options)

    def ok(body = { "ok" => true }) = ->(_req) { [ 200, body ] }

    test "sends the bearer token and returns the parsed object" do
      @fake.on("GET", "/api/v1/authenticated/me", &ok({ "id" => 7 }))
      body = client_for(connect_hackatime(@user)).get_json("/api/v1/authenticated/me", a: "b")

      assert_equal({ "id" => 7 }, body)
      request = @fake.requests.last
      assert_equal "Bearer #{SECRET_TOKEN}", request.headers["authorization"]
      assert_equal({ "a" => "b" }, request.query)
    end

    test "an expired token is refreshed first, and the new tokens are stored" do
      @fake.on("POST", "/oauth/token") do |req|
        assert_equal "refresh_token", req.form["grant_type"]
        assert_equal SECRET_REFRESH, req.form["refresh_token"]
        [ 200, { "access_token" => "new-access", "refresh_token" => "new-refresh", "expires_in" => 3600, "scope" => "profile read" } ]
      end
      @fake.on("GET", "/x", &ok)
      connection = connect_hackatime(@user, refresh_token: SECRET_REFRESH, expires_at: 1.hour.ago)

      client_for(connection).get_json("/x")

      assert_equal "Bearer new-access", @fake.requests_for("GET", "/x").first.headers["authorization"]
      connection.reload
      assert_equal "new-access", connection.access_token
      assert_equal "new-refresh", connection.refresh_token
      assert_in_delta 1.hour.from_now.to_f, connection.expires_at.to_f, 5
      assert_not connection.needs_reconnect?
    end

    test "a rejected refresh marks the connection as needing a reconnect and raises" do
      @fake.on("POST", "/oauth/token") { |_req| [ 400, { "error" => "invalid_grant" } ] }
      connection = connect_hackatime(@user, refresh_token: SECRET_REFRESH, expires_at: 1.hour.ago)

      error = assert_raises(Client::AuthError) { client_for(connection).get_json("/x") }

      assert_equal "refresh_rejected", error.code
      connection.reload
      assert connection.needs_reconnect?
      assert_equal "refresh_rejected", connection.last_error_code
      assert_empty @fake.requests_for("GET", "/x")
    end

    test "an expired token with no refresh token needs a reconnect" do
      connection = connect_hackatime(@user, expires_at: 1.hour.ago)

      assert_raises(Client::AuthError) { client_for(connection).get_json("/x") }
      assert connection.reload.needs_reconnect?
      assert_equal "no_refresh_token", connection.last_error_code
    end

    test "a 401 from the API without a refresh token marks needs_reconnect, and later calls fail fast" do
      @fake.on("GET", "/x") { |_req| [ 401, { "error" => "Unauthorized" } ] }
      connection = connect_hackatime(@user)

      assert_raises(Client::AuthError) { client_for(connection).get_json("/x") }
      assert connection.reload.needs_reconnect?

      @fake.requests.clear
      assert_raises(Client::AuthError) { client_for(connection).get_json("/x") }
      assert_empty @fake.requests, "a connection that needs reconnecting must not call Hackatime"
    end

    test "a 401 is rescued by refreshing when a refresh token exists" do
      calls = 0
      @fake.on("GET", "/x") { |req| (calls += 1) == 1 ? [ 401, {} ] : [ 200, { "seen" => req.headers["authorization"] } ] }
      @fake.on("POST", "/oauth/token") { |_req| [ 200, { "access_token" => "fresh" } ] }
      connection = connect_hackatime(@user, refresh_token: SECRET_REFRESH)

      assert_equal({ "seen" => "Bearer fresh" }, client_for(connection).get_json("/x"))
      assert_not connection.reload.needs_reconnect?
    end

    test "429 and 5xx are retryable and do not mark the connection" do
      connection = connect_hackatime(@user)
      { 429 => "rate_limited", 500 => "server_error", 503 => "server_error" }.each do |status, code|
        @fake.on("GET", "/x") { |_req| [ status, { "error" => "nope" } ] }
        error = assert_raises(Client::RetryableError) { client_for(connection).get_json("/x") }
        assert_equal code, error.code
      end
      assert_not connection.reload.needs_reconnect?
    end

    test "a refresh that hits a 5xx is retryable and keeps the connection usable" do
      @fake.on("POST", "/oauth/token") { |_req| [ 503, {} ] }
      connection = connect_hackatime(@user, refresh_token: SECRET_REFRESH, expires_at: 1.hour.ago)

      assert_raises(Client::RetryableError) { client_for(connection).get_json("/x") }
      assert_not connection.reload.needs_reconnect?
    end

    test "a connection that cannot be reached is retryable" do
      @fake.stop
      assert_raises(Client::RetryableError) { client_for(connect_hackatime(@user)).get_json("/x") }
    end

    test "a slow response times out as retryable" do
      @fake.on("GET", "/x") { |_req| sleep 1; [ 200, {} ] }
      assert_raises(Client::RetryableError) { client_for(connect_hackatime(@user), read_timeout: 0.2).get_json("/x") }
    end

    test "redirects are not followed" do
      @fake.on("GET", "/x") { |_req| [ 302, "", { "Location" => "#{@fake.url}/elsewhere" } ] }
      error = assert_raises(Client::ResponseError) { client_for(connect_hackatime(@user)).get_json("/x") }
      assert_equal "unexpected_redirect", error.code
      assert_empty @fake.requests_for("GET", "/elsewhere")
    end

    test "an oversized response is refused" do
      @fake.on("GET", "/x") { |_req| [ 200, { "blob" => "a" * 5_000 } ] }
      error = assert_raises(Client::ResponseError) { client_for(connect_hackatime(@user), max_response_bytes: 1_000).get_json("/x") }
      assert_equal "response_too_large", error.code
    end

    test "a body that is not a JSON object is a response error, not an exception" do
      connection = connect_hackatime(@user)
      [ "<html>oops</html>", "[1,2]", "" ].each do |body|
        @fake.on("GET", "/x") { |_req| [ 200, body ] }
        assert_raises(Client::ResponseError) { client_for(connection).get_json("/x") }
      end
    end

    test "tokens, secrets and bodies never reach the log" do
      @fake.on("GET", "/x") { |_req| [ 500, { "echo" => SECRET_TOKEN } ] }
      @fake.on("POST", "/oauth/token") { |_req| [ 400, { "echo" => SECRET_REFRESH } ] }
      connection = connect_hackatime(@user, refresh_token: SECRET_REFRESH)

      logs = capture_logs do
        assert_raises(Client::RetryableError) { client_for(connection).get_json("/x") }
        connection.update_columns(expires_at: 1.hour.ago)
        assert_raises(Client::AuthError) { client_for(connection).get_json("/x") }
      end

      [ SECRET_TOKEN, SECRET_REFRESH, "csecret" ].each { |secret| assert_not_includes logs, secret }
    end

    test "revoke posts the token and never raises, even when Hackatime is down" do
      @fake.on("POST", "/oauth/revoke") { |_req| [ 200, {} ] }
      Client.revoke(SECRET_TOKEN, base_url: @fake.url)
      assert_equal SECRET_TOKEN, @fake.requests_for("POST", "/oauth/revoke").first.form["token"]

      @fake.stop
      assert_nil Client.revoke(SECRET_TOKEN, base_url: @fake.url)
    end

    test "revoke with a timeout gives up on a slow Hackatime" do
      @fake.on("POST", "/oauth/revoke") do |_req|
        sleep 1.5
        [ 200, {} ]
      end
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_nil Client.revoke(SECRET_TOKEN, base_url: @fake.url, timeout: 0.3)
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1.2
    end

    test "production refuses a non-https Hackatime URL" do
      connection = connect_hackatime(@user)
      as_production do
        error = assert_raises(Client::ResponseError) { client_for(connection).get_json("/x") }
        assert_equal "insecure_url", error.code
      end
    end
  end
end
