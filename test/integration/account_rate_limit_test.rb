require "test_helper"

class AccountRateLimitTest < ActionDispatch::IntegrationTest
  # See rack_attack_test.rb: freeze at the start of a window so the counter cannot reset mid-test.
  WINDOW_START = Time.utc(2030, 1, 1, 12, 0, 0)

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

  test "account paths are limited to 20 requests a minute per IP" do
    20.times { get "/account/export", headers: { "REMOTE_ADDR" => "203.0.113.50" } }
    assert_not_equal 429, response.status
    get "/account/export", headers: { "REMOTE_ADDR" => "203.0.113.50" }
    assert_response :too_many_requests
    delete "/account", headers: { "REMOTE_ADDR" => "203.0.113.50" }
    assert_response :too_many_requests
    get "/account", headers: { "REMOTE_ADDR" => "203.0.113.51" }
    assert_not_equal 429, response.status
  end

  test "the limit covers deletion attempts, so the confirmation phrase cannot be brute forced" do
    21.times { delete "/account", params: { confirmation: "x" }, headers: { "REMOTE_ADDR" => "203.0.113.60" } }
    assert_response :too_many_requests
  end

  test "the account limit does not touch other pages" do
    21.times { get "/privacy", headers: { "REMOTE_ADDR" => "203.0.113.70" } }
    assert_response :success
  end
end
