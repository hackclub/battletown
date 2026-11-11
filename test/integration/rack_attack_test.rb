require "test_helper"

class RackAttackTest < ActionDispatch::IntegrationTest
  setup do
    Rack::Attack.enabled = true
    Rack::Attack.cache.store.clear
  end

  teardown do
    Rack::Attack.cache.store.clear
    Rack::Attack.enabled = false
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
