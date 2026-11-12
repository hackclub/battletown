require "test_helper"

class AdminMetricsPageTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    @original_env = ENV["ADMIN_HCA_UIDS"]
    @detailed = Rails.application.env_config["action_dispatch.show_detailed_exceptions"]
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = false
    @admin = users(:onboarded)
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = @detailed
    @original_env.nil? ? ENV.delete("ADMIN_HCA_UIDS") : ENV["ADMIN_HCA_UIDS"] = @original_env
  end

  def sign_in_as(user)
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
  end

  def sign_in_admin
    ENV["ADMIN_HCA_UIDS"] = @admin.hca_uid
    sign_in_as @admin
  end

  # Users who each coded on a few recent days, so every table has rows to group.
  def add_users(count)
    today = Time.current.utc.to_date
    users = Array.new(count) { |n| User.create!(hca_uid: "metrics-page-#{SecureRandom.hex(4)}-#{n}", display_name: "Person #{n}") }
    rows = users.each_with_index.flat_map do |user, n|
      [ 0, 1, n % 20 ].uniq.map do |back|
        { user_id: user.id, local_date: today - back, seconds: 1200, source: "manual", note: "test", idempotency_key: SecureRandom.hex(8) }
      end
    end
    HourEntry.insert_all!(rows)
  end

  def count_queries
    count = 0
    counter = ->(*, payload) { count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) || payload[:sql].match?(/\A\s*(BEGIN|COMMIT|SAVEPOINT|RELEASE)/i) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end

  test "signed-out visitors and non-admins get the same 404 as an unknown path" do
    get "/definitely-not-a-page"
    missing = response.body

    get "/admin/metrics"
    assert_response :not_found
    assert_equal missing, response.body

    ENV["ADMIN_HCA_UIDS"] = "someone-else"
    sign_in_as @admin
    get "/admin/metrics"
    assert_response :not_found
  end

  test "an admin sees the orange, no-store metrics page with accessible tables and written definitions" do
    add_users(3)
    sign_in_admin
    get "/admin/metrics"
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_select ".admin-only h1", "Metrics"
    assert_select ".admin-only table.admin-table", 4
    assert_select "table caption", 4
    assert_select "table tbody th[scope=row]", AdminMetrics::DAYS + AdminMetrics::WEEKS + AdminMetrics::FUNNEL_STEPS.size + AdminMetrics::DROPOUT_DAYS + 2
    assert_select "progress[aria-hidden=true]"
    assert_select "p", /coded at least 15 minutes that day/
    assert_select "p", /Friday to Thursday/
    assert_select "[style]", 0
    assert_select "script:not([nonce])", 0
  end

  test "the admin dashboard links to it" do
    sign_in_admin
    get "/admin"
    assert_select "a[href='#{admin_metrics_path}']", "Metrics"
  end

  test "the page shows no names, emails or ids" do
    add_users(3)
    @admin.update!(slack_id: "U0SLACKPII")
    sign_in_admin
    get "/admin/metrics"
    content = css_select(".admin-metrics").to_s
    User.find_each do |user|
      [ user.email, user.display_name, user.slack_id, user.hca_uid ].compact.each { |pii| assert_not_includes content, pii }
    end
  end

  test "the page runs the same number of queries for 3 users as for 30" do
    sign_in_admin
    add_users(3)
    few = count_queries { get "/admin/metrics" }
    assert_response :success

    add_users(27)
    many = count_queries { get "/admin/metrics" }
    assert_response :success
    assert_equal few, many
    assert_operator few, :<=, 8, "expected a small fixed number of queries"
  end
end
