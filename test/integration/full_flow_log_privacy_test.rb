require "test_helper"
require_relative "../support/ships_test_support"
require_relative "../support/hackatime_helper"
require_relative "../support/shop_helper"

# One teen goes through every feature while the application logger is captured at the production level (info),
# plus the request logger and the database logger at debug (more than production writes). Nothing personal may appear.
class FullFlowLogPrivacyTest < ActionDispatch::IntegrationTest
  include ShipsTestSupport
  include HackatimeHelper
  include ShopTestHelper

  EMAIL = "probe.teen@example.com".freeze
  NAME = "Probe Teenager".freeze
  SLACK = "U0PROBE123".freeze
  IDEA = "PROBE-IDEA-TEXT".freeze
  DESCRIPTION = "PROBE-DESCRIPTION-TEXT".freeze
  REPO = "https://github.com/probe-user/probe-repo".freeze
  HACKATIME_NAME = "probe-hackatime-name".freeze
  NOTE = "PROBE-REJECT-NOTE".freeze

  setup do
    OmniAuth.config.test_mode = true
    @original_admins = ENV["ADMIN_HCA_UIDS"]
    @original_enabled = ENV["NOTIFICATIONS_ENABLED"]
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
    @original_admins.nil? ? ENV.delete("ADMIN_HCA_UIDS") : ENV["ADMIN_HCA_UIDS"] = @original_admins
    @original_enabled.nil? ? ENV.delete("NOTIFICATIONS_ENABLED") : ENV["NOTIFICATIONS_ENABLED"] = @original_enabled
  end

  def sign_in_with(user, claims = {})
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: claims })
    post "/auth/hack_club"
    follow_redirect!
  end

  def capture_everything
    io = StringIO.new
    loggers = [ Rails.logger, ActionController::Base.logger, ActiveRecord::Base.logger ]
    shared = ActiveSupport::Logger.new(io)
    Rails.logger = ActionController::Base.logger = ActiveRecord::Base.logger = shared
    shared.level = Logger::DEBUG
    yield
    io.string
  ensure
    Rails.logger, ActionController::Base.logger, ActiveRecord::Base.logger = loggers
  end

  test "a whole flow (sign-in, onboarding, project, hours, ship, review, shop, notifications) logs no personal data" do
    teen = users(:new_user)
    reviewer = users(:onboarded)
    ENV["ADMIN_HCA_UIDS"] = reviewer.hca_uid
    ENV["NOTIFICATIONS_ENABLED"] = "true"
    claims = { "email" => EMAIL, "name" => NAME, "slack_id" => SLACK, "verification_status" => "verified" }

    log = capture_everything do
      sign_in_with(teen, claims)
      patch onboarding_step_path("prize"), params: { user: { prize_key: "keychain" } }
      patch onboarding_step_path("project"), params: { user: { project_kind: "game", project_idea: IDEA } }
      patch onboarding_step_path("schedule"), params: { user: { coding_day_names: %w[monday friday], coding_time: "18:30", time_zone: "UTC" } }
      patch onboarding_step_path("account"), params: { user: {} }
      patch onboarding_step_path("celebrate"), params: { user: {} }
      teen.reload.update_columns(created_at: Time.utc(2026, 11, 1, 12), signed_up_on: Date.new(2026, 11, 1))

      project = teen.projects.first
      post project_hackatime_links_path(project), params: { hackatime_link: { hackatime_project: HACKATIME_NAME } }
      (7..9).each { |day| code(teen, Date.new(2026, 11, day), HOUR, hackatime: HACKATIME_NAME) }
      Game::Settle.call(teen, through: Time.utc(2026, 11, 11, 12))
      get dashboard_path
      post project_ships_path(project), params: { ship: { description: DESCRIPTION, repo_url: REPO }, ship_action: "submit" }
      ship = teen.ships.last
      patch settings_notifications_path, params: { preferences: { ship_mvp: "0" } }
      get settings_notifications_path
      get ships_path
      get shop_path

      delete logout_path
      sign_in_with(reviewer)
      get admin_ship_path(ship)
      patch reject_admin_ship_path(ship), params: { reason_note: NOTE }
      delete logout_path

      sign_in_with(teen, claims)
      post project_ships_path(project), params: { ship: { description: DESCRIPTION, repo_url: REPO }, ship_action: "submit" }
      delete logout_path
      sign_in_with(reviewer)
      patch approve_admin_ship_path(teen.ships.last)
      delete logout_path

      sign_in_with(teen, claims)
      post_order_as teen, prize_key: "custom_sticker"
      get orders_path
      connect_hackatime(teen)
      get hackatime_path
      Notifications::Dispatcher.run
    end

    assert_operator log.length, :>, 2_000, "the flow should have logged plenty of lines"
    [ EMAIL, NAME, SLACK, IDEA, DESCRIPTION, REPO, "probe-repo", HACKATIME_NAME, NOTE, SECRET_TOKEN ].each do |needle|
      assert_not_includes log, needle, "#{needle.inspect} must not appear in the logs"
    end
    assert_no_match(/xox[bpa]-/, log)
  end
end
