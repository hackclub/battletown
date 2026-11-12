require "test_helper"

class RackAttackTest < ActionDispatch::IntegrationTest
  # Throttle keys are Time.now.to_i / period, so a test that sends limit + 1 requests can straddle a window
  # boundary (a slow first request is enough) and see the count reset. Freezing time at the very start of a
  # window keeps every request in the same one.
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

  test "throttle counters use a real store, not the null Rails.cache" do
    assert_instance_of ActiveSupport::Cache::MemoryStore, Rack::Attack.cache.store.then { |store| store.respond_to?(:store) ? store.store : store }
  end

  test "auth request phase is limited to 10 POSTs a minute per IP" do
    10.times { post "/auth/hack_club", headers: { "REMOTE_ADDR" => "203.0.113.7" } }
    post "/auth/hack_club", headers: { "REMOTE_ADDR" => "203.0.113.7" }
    assert_response :too_many_requests
    post "/auth/hack_club", headers: { "REMOTE_ADDR" => "203.0.113.8" }
    assert_not_equal 429, response.status
  end

  test "crew invite links are limited to 30 a minute per IP, so tokens cannot be guessed in bulk" do
    30.times { get "/team/join/#{'a' * 16}", headers: { "REMOTE_ADDR" => "203.0.113.20" } }
    get "/team/join/#{'a' * 16}", headers: { "REMOTE_ADDR" => "203.0.113.20" }
    assert_response :too_many_requests
    get "/team/join/#{'a' * 16}", headers: { "REMOTE_ADDR" => "203.0.113.21" }
    assert_not_equal 429, response.status
  end

  test "staff user writes are limited to 30 a minute per IP and reads to 120, in separate buckets" do
    30.times { post "/admin/users/1/coins", headers: { "REMOTE_ADDR" => "203.0.113.30" } }
    assert_not_equal 429, response.status
    post "/admin/users/1/coins", headers: { "REMOTE_ADDR" => "203.0.113.30" }
    assert_response :too_many_requests
    get "/admin/users", headers: { "REMOTE_ADDR" => "203.0.113.30" }
    assert_not_equal 429, response.status, "reading has its own bucket"
    post "/admin/users/1/coins", headers: { "REMOTE_ADDR" => "203.0.113.31" }
    assert_not_equal 429, response.status

    120.times { get "/admin/users", headers: { "REMOTE_ADDR" => "203.0.113.32" } }
    assert_not_equal 429, response.status
    get "/admin/users", headers: { "REMOTE_ADDR" => "203.0.113.32" }
    assert_response :too_many_requests
  end

  test "a spoofed leading X-Forwarded-For entry does not reset the limit behind a proxy" do
    11.times do |i|
      post "/auth/hack_club", headers: { "REMOTE_ADDR" => "10.0.0.2", "X-Forwarded-For" => "198.51.100.#{i}, 203.0.113.9" }
    end
    assert_response :too_many_requests
  end

  test "dev_login is throttled too" do
    11.times { post "/dev_login", headers: { "REMOTE_ADDR" => "203.0.113.20" } }
    assert_response :too_many_requests
  end
end
