require "test_helper"
require_relative "../support/ships_test_support"
require_relative "../support/shop_helper"

# Table-driven checks that read the router, so a route added later is covered without anyone remembering to list it.
class RouteSecurityTest < ActionDispatch::IntegrationTest
  include ShipsTestSupport
  include ShopTestHelper

  STATE_CHANGING = %w[POST PATCH PUT DELETE].freeze

  setup do
    OmniAuth.config.test_mode = true
    @original_admins = ENV["ADMIN_HCA_UIDS"]
    @detailed = Rails.application.env_config["action_dispatch.show_detailed_exceptions"]
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = false
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = @detailed
    @original_admins.nil? ? ENV.delete("ADMIN_HCA_UIDS") : ENV["ADMIN_HCA_UIDS"] = @original_admins
  end

  def sign_in_as(user)
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
  end

  # [verb, path template, controller] for every concrete route (one entry per verb), skipping the framework's own.
  def app_routes
    Rails.application.routes.routes.flat_map do |route|
      verbs = route.verb.to_s.split("|").presence || [ "ANY" ]
      path = route.path.spec.to_s.sub("(.:format)", "")
      controller = route.defaults[:controller].to_s
      next [] if controller.start_with?("rails/", "active_storage/", "action_mailbox/") || path.start_with?("/rails/", "/assets")

      verbs.map { |verb| [ verb.gsub(/[^A-Z]/, ""), path, controller, route ] }.reject { |verb, *| verb == "ANY" || verb.empty? }
    end
  end

  def fill(path, params)
    path.gsub(/:(\w+)/) { params.fetch(Regexp.last_match(1).to_sym, "1").to_s }
  end

  test "no framework upload, mailbox or conductor endpoints are routed" do
    framework = Rails.application.routes.routes.map { |route| route.path.spec.to_s }.select { |path| path.start_with?("/rails/") }
    assert_equal [ "/up" ], Rails.application.routes.routes.map { |route| route.path.spec.to_s }.grep(%r{\A/up}).map { |path| path.sub("(.:format)", "") }
    assert_empty framework, "unexpected framework routes: #{framework.join(', ')}"
    assert_not defined?(ActiveStorage::Engine), "Active Storage is not used and must stay out of the app"
    assert_not defined?(ActionMailbox::Engine), "Action Mailbox is not used and must stay out of the app"
  end

  # app_routes only lists controller routes; a mounted Rack app brings its own routes, so each must be listed here.
  test "every mounted Rack app is known, and the Flipper console sits behind the admin-only constraint" do
    mounted = Rails.application.routes.routes.reject { |route| route.defaults[:controller] }
    assert_equal [ "/admin/flipper", "/cable" ], mounted.map { |route| route.path.spec.to_s }.sort, "a new mounted app needs its own security test"

    flipper = mounted.find { |route| route.path.spec.to_s == "/admin/flipper" }
    assert_equal [ Features::AdminConstraint ], flipper.app.constraints.map(&:class)
  end

  # --- (b) every /admin route is a 404 for the signed-out and for non-admins ---

  test "every admin route is a 404 for signed-out visitors and non-admins, whatever the verb" do
    boss = Bosses::Seed.call && Boss.chronological.last
    teen = users(:new_user)
    teen.update_columns(onboarded_at: Time.utc(2026, 11, 2), onboarding_step: 4, created_at: Time.utc(2026, 11, 1, 12), signed_up_on: Date.new(2026, 11, 1))
    project = make_project(teen)
    code(teen, Date.new(2026, 11, 8), HOUR)
    ship = submit_ship(project)
    verified!(teen)
    give_coins(teen, 100)
    order = buy(teen, "keychain")
    ids = { "admin/bosses" => boss.id, "admin/ships" => ship.id, "admin/orders" => order.id }

    routes = app_routes.select { |_verb, path, _controller, _route| path == "/admin" || path.start_with?("/admin/") }
    assert_operator routes.size, :>=, 10, "expected the admin routes to be found in the router"

    ENV["ADMIN_HCA_UIDS"] = "someone-else"
    [ nil, users(:onboarded), teen ].each do |visitor|
      delete logout_path if visitor
      sign_in_as(visitor) if visitor
      routes.each do |verb, path, controller, _route|
        url = fill(path, id: ids.fetch(controller, 1))
        process(verb.downcase.to_sym, url)
        assert_response :not_found, "#{verb} #{url} must be a 404 for #{visitor ? 'a signed-in non-admin' : 'a signed-out visitor'}"
      end
    end

    assert_equal "submitted", ship.reload.status
    assert_equal "requested", order.reload.status

    # Positive control: the same GET routes are reachable for a real admin, so the 404s above come from the admin check.
    delete logout_path
    ENV["ADMIN_HCA_UIDS"] = users(:onboarded).hca_uid
    sign_in_as users(:onboarded)
    routes.select { |verb, path, *| verb == "GET" && !path.include?(":") }.each do |_verb, path, *|
      get path
      assert_response :success, "GET #{path} should open for an admin"
    end
  end

  # --- (c) other people's records are a 404 on every user-scoped route ---

  test "every user-scoped route answers 404 for someone else's ids and changes nothing" do
    owner = users(:onboarded)
    owner.update_columns(created_at: Time.utc(2026, 11, 1, 12), signed_up_on: Date.new(2026, 11, 1))
    stranger = users(:new_user)
    stranger.update_columns(onboarded_at: Time.utc(2026, 11, 2), onboarding_step: 4)
    project = make_project(owner)
    link = project.hackatime_links.first
    suggestion = project.link_suggestions.create!(hackatime_project: "other-name")
    code(owner, Date.new(2026, 11, 8), HOUR)
    ship = submit_ship(project)
    verified!(owner)
    give_coins(owner, 100)
    order = buy(owner, "keychain")

    scoped = %w[projects hackatime_links link_suggestions ships orders]
    ids = { "projects" => project.id, "hackatime_links" => link.id, "link_suggestions" => suggestion.id, "ships" => ship.id, "orders" => order.id }
    routes = app_routes.select { |_verb, path, controller, _route| scoped.include?(controller) && path.include?(":") }
    assert_operator routes.size, :>=, 15, "expected the user-scoped routes to be found in the router"

    sign_in_as(stranger)
    routes.each do |verb, path, controller, _route|
      url = fill(path, project_id: project.id, id: ids.fetch(controller))
      process(verb.downcase.to_sym, url)
      assert_response :not_found, "#{verb} #{url} must be a 404 for another user"
    end

    assert_equal "submitted", ship.reload.status
    assert_equal "requested", order.reload.status
    assert Project.exists?(project.id) && HackatimeLink.exists?(link.id) && LinkSuggestion.exists?(suggestion.id)
    assert_equal "pending", suggestion.reload.state
  end

  test "the singular settings pages only ever touch the signed-in user's own rows" do
    owner = users(:onboarded)
    stranger = users(:new_user)
    stranger.update_columns(onboarded_at: Time.utc(2026, 11, 2), onboarding_step: 4)
    owner_pref = NotificationPreference.create!(user: owner, kind: "ship_approved", enabled: true)
    HackatimeConnection.create!(user: owner, hackatime_uid: "42", access_token: "dummy-token-1", scopes: "profile read", connected_at: Time.current)

    sign_in_as(stranger)
    patch settings_notifications_path, params: { preferences: { ship_approved: "0" } }
    delete hackatime_path
    assert owner_pref.reload.enabled, "someone else's notification switch must not change"
    assert_not_nil owner.reload.hackatime_connection, "someone else's Hackatime connection must not be removed"
    assert_equal 1, NotificationPreference.where(user_id: stranger.id, kind: "ship_approved", enabled: false).count
  end

  # --- (d) every state-changing route is CSRF protected, except the bearer-token privacy API ---

  # Forgery protection is off in tests; these turn it on like production. Sign in first (the OmniAuth POST has no token).
  def with_forgery_protection
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    yield
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  # The login and admin checks run before the CSRF check, so an admin write without a token is the same 404 as an
  # unknown path for everyone but a real admin (a 422 would reveal that the route exists).
  test "admin write routes are a 404, not a CSRF error, for signed-out visitors and non-admins" do
    ENV["ADMIN_HCA_UIDS"] = "someone-else"
    routes = app_routes.select { |verb, path, *| STATE_CHANGING.include?(verb) && path.start_with?("/admin/") }
    assert_operator routes.size, :>=, 5, "expected the admin write routes to be found in the router"

    [ nil, users(:onboarded) ].each do |visitor|
      if visitor
        sign_in_as(visitor)
        assert_equal visitor.id, session[:user_id]
      end
      with_forgery_protection do
        routes.each do |verb, path, *|
          process(verb.downcase.to_sym, fill(path, {}))
          assert_response :not_found, "#{verb} #{path} must be a 404 for #{visitor ? 'a signed-in non-admin' : 'a signed-out visitor'}"
        end
      end
    end
  end

  test "every POST PATCH PUT and DELETE route rejects a request without a CSRF token, except /api/privacy" do
    # An admin, so the /admin writes get past the admin check and reach the CSRF check too.
    ENV["ADMIN_HCA_UIDS"] = users(:onboarded).hca_uid
    sign_in_as users(:onboarded)
    assert_equal users(:onboarded).id, session[:user_id]
    with_forgery_protection do
      routes = app_routes.select { |verb, _path, _controller, _route| STATE_CHANGING.include?(verb) }
      exempt, protected_routes = routes.partition { |_verb, path, _controller, _route| path.start_with?("/api/privacy") }
      assert_operator protected_routes.size, :>=, 30, "expected the state-changing routes to be found in the router"
      assert_operator exempt.size, :>=, 2

      protected_routes.each do |verb, path, _controller, _route|
        url = fill(path, step: "prize", provider: "hack_club", key: "keychain")
        process(verb.downcase.to_sym, url)
        assert_response :unprocessable_content, "#{verb} #{url} must reject a missing CSRF token"
      end
    end
  end
end
