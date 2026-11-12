require "test_helper"

# Routes behind a flag do not exist while it is off, and the Flipper console is for admins only (everyone else: 404).
class FeatureFlagsTest < ActionDispatch::IntegrationTest
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

  # --- the route constraint ---

  test "a constrained route does not exist while its flag is off and exists once it is on" do
    set = ActionDispatch::Routing::RouteSet.new
    set.draw do
      constraints Features::Constraint.new(:team) do
        get "/probe", to: "landing#show"
      end
    end

    assert_raises(ActionController::RoutingError) { set.recognize_path("/probe") }
    with_feature(:team) { assert_equal "show", set.recognize_path("/probe")[:action] }
    without_feature(:team) { assert_raises(ActionController::RoutingError) { set.recognize_path("/probe") } }
  end

  test "a constraint on an unknown flag fails when the routes are drawn" do
    assert_raises(ArgumentError) { Features::Constraint.new(:tem) }
  end

  # --- the Flipper console ---

  test "the Flipper console is a 404 for signed-out visitors and non-admins, whatever the verb" do
    ENV["ADMIN_HCA_UIDS"] = "someone-else"
    paths = %w[/admin/flipper /admin/flipper/features /admin/flipper/features/team /admin/flipper/features/team/boolean /admin/flipper/settings]

    [ nil, users(:onboarded), users(:new_user) ].each do |visitor|
      delete logout_path if visitor
      sign_in_as(visitor) if visitor
      paths.each do |path|
        %i[get post put patch delete].each do |verb|
          process(verb, path)
          assert_response :not_found, "#{verb.upcase} #{path} must be a 404 for #{visitor ? 'a signed-in non-admin' : 'a signed-out visitor'}"
        end
      end
    end
    assert_not Features.enabled?(:team)
  end

  test "an admin sees every known flag, off, and flipping one in the console takes effect" do
    Features.register_known!
    sign_in_admin

    get "/admin/flipper/features"
    assert_response :success
    Features::NAMES.each { |name| assert_includes response.body, name.to_s }

    get "/admin/flipper/features/team"
    assert_response :success
    token = css_select("input[name=authenticity_token]").first["value"]
    post "/admin/flipper/features/team/boolean", params: { action: "Enable", authenticity_token: token }
    assert_response :redirect
    assert Features.enabled?(:team)
    assert_not Features.enabled?(:quests)

    get "/admin/flipper/features/team"
    token = css_select("input[name=authenticity_token]").first["value"]
    post "/admin/flipper/features/team/boolean", params: { action: "Disable", authenticity_token: token }
    assert_not Features.enabled?(:team)
  end

  test "console writes need a CSRF token, even for an admin" do
    Features.register_known!
    sign_in_admin

    post "/admin/flipper/features/team/boolean", params: { action: "Enable" }
    assert_response :forbidden
    assert_not Features.enabled?(:team)
  end

  test "the console keeps its own self-only content security policy, no inline script, no third party" do
    Features.register_known!
    sign_in_admin

    get "/admin/flipper/features"
    policy = response.headers["Content-Security-Policy"]
    assert_match(/script-src 'report-sample' 'self';/, policy)
    assert_no_match(/version\.js/, response.body, "the version check must stay off")
    assert_empty css_select("script:not([src])"), "no inline script"
  end

  test "the admin dashboard links to the console for admins" do
    sign_in_admin
    get admin_root_path
    # data-turbo=false: the console is a separate page with its own CSP; Turbo would swap it into this page's policy.
    assert_select "a[href=?][data-turbo=false]", "/admin/flipper", text: "Feature flags"
  end
end
