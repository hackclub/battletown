require "test_helper"

# Behaviour found by running a real Hack Club Auth login end to end.
class HcaLoginTest < ActionDispatch::IntegrationTest
  test "denying consent at Hack Club Auth is a friendly no-op, not an error" do
    assert_no_difference "User.count" do
      get "/auth/failure", params: { message: "access_denied", strategy: "hack_club" }
    end
    assert_redirected_to root_path
    assert_nil flash[:alert]
    assert_match(/No problem/, flash[:notice])
    assert_nil session[:user_id]
  end

  test "other failures still show the generic sign-in error" do
    get "/auth/failure", params: { message: "invalid_credentials", strategy: "hack_club" }
    assert_redirected_to root_path
    assert_match(/couldn't sign you in/, flash[:alert])
    assert_nil flash[:notice]
  end

  test "denied consent is rendered on the landing page without a stack trace" do
    get "/auth/failure", params: { message: "access_denied", strategy: "hack_club" }
    follow_redirect!
    assert_response :success
    assert_select "[role=status], .flash", text: /No problem/
    assert_no_match(/Exception|Traceback|app\/controllers/, response.body)
  end

  test "discovery lookups are cached in process, so a sign-in does not re-fetch them" do
    assert_instance_of HcaDiscoveryCache, SWD.cache

    cache = HcaDiscoveryCache.new
    calls = 0
    3.times { assert_equal "doc", cache.fetch("k", {}) { calls += 1; "doc" } }
    assert_equal 1, calls
  end

  test "discovery cache expires entries after the TTL" do
    now = 0.0
    cache = HcaDiscoveryCache.new(ttl: 60, clock: -> { now })
    calls = 0
    fetch = -> { cache.fetch("k") { calls += 1 } }

    fetch.call
    now = 59.0
    fetch.call
    assert_equal 1, calls

    now = 61.0
    fetch.call
    assert_equal 2, calls
  end

  test "discovery cache never stores failures, so a 429 is retried" do
    cache = HcaDiscoveryCache.new
    assert_raises(RuntimeError) { cache.fetch("k") { raise "slow your roll!" } }
    assert_equal "ok", cache.fetch("k") { "ok" }
  end
end
