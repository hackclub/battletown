require "test_helper"
require "open3"
require_relative "../support/hackatime_helper"

# HACKATIME_REQUIRED is the launch-day escape hatch (config.x.hackatime.required, read in config/application.rb only).
# Required (the default): onboarding_hackatime_test.rb. Optional: the account step recommends Hackatime and can be skipped,
# the last step and finishing no longer need a connection, and the dashboard's Hackatime panel still says to connect.
class OnboardingHackatimeOptionalTest < ActionDispatch::IntegrationTest
  include HackatimeHelper

  setup { OmniAuth.config.test_mode = true }

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
  end

  def sign_in_as(user)
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
  end

  def with_hackatime_required(value)
    original = Rails.configuration.x.hackatime.required
    Rails.configuration.x.hackatime.required = value
    yield
  ensure
    Rails.configuration.x.hackatime.required = original
  end

  def at_account_step(user)
    user.update!(onboarding_step: 5)
    sign_in_as user
  end

  # config/application.rb reads the variable at boot, so each value gets its own process.
  def required_after_boot(value)
    env = { "RAILS_ENV" => "test", "HACKATIME_REQUIRED" => value }
    out, status = Open3.capture2e(env, Rails.root.join("bin/rails").to_s, "runner", "print Rails.configuration.x.hackatime.required", chdir: Rails.root.to_s)
    assert status.success?, out
    out.lines.last.to_s.strip
  end

  test "the step is required unless HACKATIME_REQUIRED is 0 or false" do
    assert_equal "true", required_after_boot("")
    assert_equal "true", required_after_boot("1")
    assert_equal "false", required_after_boot("0")
    assert_equal "false", required_after_boot("False")
  end

  test "required by default: Required badge, no Skip for now, and the server still refuses" do
    user = users(:new_user)
    at_account_step(user)
    get onboarding_step_path("account")
    assert_select "#hackatime-check .badge", "Required"
    assert_select "button", text: "Skip for now", count: 0
    patch onboarding_step_path("account")
    assert_redirected_to onboarding_step_path("account")
    assert_equal 5, user.reload.onboarding_step
  end

  test "optional: Hackatime is recommended, Connect is still offered and the step can be skipped" do
    with_hackatime_required(false) do
      at_account_step(users(:new_user))
      get onboarding_step_path("account")
      assert_response :success
      assert_select "#hackatime-check .badge", "Recommended"
      assert_select "#hackatime-check form[action='/auth/hackatime'] button", "Connect Hackatime"
      assert_select "button", text: "Skip for now"
      assert_select "button", text: "Continue", count: 0
      assert_select "#hackatime-check", text: /you can skip this for now/i
      assert_no_match(/we need it before you start/, css_select("#hackatime-check").text)
    end
  end

  test "optional: skipping goes through the last step and finishes with no connection, then Hackatime is still asked for" do
    user = users(:new_user)
    with_hackatime_required(false) do
      at_account_step(user)
      patch onboarding_step_path("account"), params: { user: { referral_source: "" } }
      assert_redirected_to onboarding_step_path("celebrate")
      assert_equal 6, user.reload.onboarding_step
      get onboarding_step_path("celebrate")
      assert_response :success
      patch onboarding_step_path("celebrate")
      assert_redirected_to dashboard_path
    end
    assert user.reload.onboarded?
    assert_nil user.hackatime_connection

    get dashboard_path
    assert_response :success
    panel = Dashboard::Presenter.new(user: user).hackatime
    assert_equal :not_connected, panel.state
    assert_match(/Connect Hackatime/, panel.message)
  end

  test "optional: someone who did connect sees Continue, not Skip for now, and a lapsed connection does not block" do
    user = users(:new_user)
    with_hackatime_required(false) do
      connect_hackatime(user)
      at_account_step(user)
      get onboarding_step_path("account")
      assert_select "#hackatime-check .badge", "Connected"
      assert_select "button", text: "Continue"
      assert_select "button", text: "Skip for now", count: 0

      other = User.create!(hca_uid: "ident!lapsed-optional", onboarding_step: 6)
      connect_hackatime(other, uid: "5252", needs_reconnect: true)
      reset!
      sign_in_as other
      patch onboarding_step_path("celebrate")
      assert_redirected_to dashboard_path
      assert other.reload.onboarded?
    end
  end

  test "optional: declining Hackatime says it can be connected later, not that it is needed" do
    with_hackatime_required(false) do
      at_account_step(users(:new_user))
      get "/auth/failure", params: { strategy: "hackatime", message: "access_denied" }
      assert_redirected_to onboarding_step_path("account")
      assert_match(/connect it later/, flash[:notice])
    end
    get "/auth/failure", params: { strategy: "hackatime", message: "access_denied" }
    assert_match(/need it to finish signing up/, flash[:notice])
  end
end
