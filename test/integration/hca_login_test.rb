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

  test "a stale sign-in link says it expired, not that sign-in failed" do
    %w[authenticity_error csrf_detected].each do |message|
      get "/auth/failure", params: { message: message, strategy: "hack_club" }
      assert_redirected_to root_path
      assert_equal "That sign-in link expired. Please try again.", flash[:alert], message
      assert_nil session[:user_id]
    end
    follow_redirect!
    assert_select ".flash", text: /That sign-in link expired/
  end

  test "a sign-in form posted with a stale CSRF token lands on the expired message, not the bare 422 page" do
    with_forgery_protection do
      post "/auth/hack_club", params: { authenticity_token: "stale" }
      assert_redirected_to "/auth/failure?message=authenticity_error&strategy=hack_club"
      follow_redirect!
      assert_redirected_to root_path
      assert_equal "That sign-in link expired. Please try again.", flash[:alert]
    end
  end

  test "the CSRF check is translated for OmniAuth and a good token still passes" do
    stale = FriendlyCsrfVerifier.new(->(_env) { raise ActionController::InvalidAuthenticityToken })
    assert_raises(OmniAuth::AuthenticityError) { stale.call({}) }
    fine = FriendlyCsrfVerifier.new(->(_env) { :ok })
    assert_equal :ok, fine.call({})
    assert_instance_of FriendlyCsrfVerifier, OmniAuth.config.request_validation_phase
    assert_instance_of OmniAuth::RailsCsrfProtection::TokenVerifier, OmniAuth.config.request_validation_phase.instance_variable_get(:@inner)
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

  private

  # Test mode skips OmniAuth's request phase (and its CSRF check) and forgery protection is off in the test environment.
  def with_forgery_protection
    mode = OmniAuth.config.test_mode
    protection = ActionController::Base.allow_forgery_protection
    OmniAuth.config.test_mode = false
    ActionController::Base.allow_forgery_protection = true
    yield
  ensure
    OmniAuth.config.test_mode = mode
    ActionController::Base.allow_forgery_protection = protection
  end
end
