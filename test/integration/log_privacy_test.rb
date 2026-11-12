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

  # The token in these three paths is the whole credential (an invite to a crew, a survey answer, an unsubscribe), and Rails
  # filters only the query string: the request line in the log must not carry it (config/initializers/filter_path_tokens.rb).
  test "bearer tokens in the URL path never reach the request log" do
    secret = "TOKENSECRET#{SecureRandom.hex(8)}"
    %w[team nps email].each { |name| Flipper.enable(name) }
    io = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    begin
      [ "/team/join/#{secret}", "/feedback/#{secret}#{'x' * 20}", "/email/unsubscribe/#{secret}" ].each { |path| get path }
    ensure
      Rails.logger = original
    end
    log = io.string
    assert_includes log, 'Started GET "/team/join/[FILTERED]"'
    assert_includes log, 'Started GET "/feedback/[FILTERED]"'
    assert_includes log, 'Started GET "/email/unsubscribe/[FILTERED]"'
    assert_not_includes log, secret

    get "/privacy?x=1"
    assert_equal "/privacy?x=1", request.filtered_path, "other paths are untouched"
  end
end
