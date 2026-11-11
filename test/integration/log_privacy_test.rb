require "test_helper"

class LogPrivacyTest < ActionDispatch::IntegrationTest
  test "free-text and profile params are filtered from request logs" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    params = { "user" => { "project_idea" => "my secret idea", "display_name" => "Kid", "time_zone" => "UTC",
                           "email" => "kid@example.com", "prize_key" => "tshirt", "coding_day_names" => [ "monday" ] },
               "code" => "abc", "state" => "xyz" }
    filtered = filter.filter(params)
    assert_equal ActiveSupport::ParameterFilter::FILTERED, filtered.dig("user", "project_idea")
    %w[display_name time_zone email prize_key coding_day_names].each do |key|
      assert_equal ActiveSupport::ParameterFilter::FILTERED, filtered.dig("user", key), key
    end
    assert_equal ActiveSupport::ParameterFilter::FILTERED, filtered["code"]
    assert_equal ActiveSupport::ParameterFilter::FILTERED, filtered["state"]
  end

  test "onboarding submission does not write the idea text to the log" do
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: users(:new_user).hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
    io = StringIO.new
    old = ActionController::Base.logger
    ActionController::Base.logger = ActiveSupport::Logger.new(io)
    begin
      patch onboarding_step_path("prize"), params: { user: { prize_key: "tshirt" } }
      patch onboarding_step_path("project"), params: { user: { project_kind: "game", project_idea: "UNIQUE-IDEA-TEXT-123" } }
    ensure
      ActionController::Base.logger = old
      OmniAuth.config.test_mode = false
    end
    assert_includes io.string, "Parameters:"
    assert_not_includes io.string, "UNIQUE-IDEA-TEXT-123"
  end
end
