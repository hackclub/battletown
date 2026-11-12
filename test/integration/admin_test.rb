require "test_helper"

class AdminTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    @original_env = ENV["ADMIN_HCA_UIDS"]
    # Render the public 404 page like production does, not the detailed debug page (which names the controller).
    @detailed = Rails.application.env_config["action_dispatch.show_detailed_exceptions"]
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = false
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

  def make_admin(user) = ENV["ADMIN_HCA_UIDS"] = " other-id, #{user.hca_uid} "

  def not_found_body
    get "/definitely-not-a-page"
    assert_response :not_found
    response.body
  end

  test "signed-out GET /admin is the same 404 as an unknown path, not a redirect" do
    missing = not_found_body
    get "/admin"
    assert_response :not_found
    assert_equal missing, response.body
  end

  test "a signed-in non-admin gets the same 404" do
    sign_in_as users(:onboarded)
    missing = not_found_body
    get "/admin"
    assert_response :not_found
    assert_equal missing, response.body
  end

  test "an id that only partially matches the allowlist is not an admin" do
    ENV["ADMIN_HCA_UIDS"] = "ident!onboard,ident!onboarded2,IDENT!ONBOARDED"
    sign_in_as users(:onboarded)
    get "/admin"
    assert_response :not_found
  end

  test "every admin table sits in a named, keyboard-focusable scroll region, and the page has one h1" do
    make_admin(users(:onboarded))
    sign_in_as users(:onboarded)
    get "/admin"
    assert_select ".table-wrap[tabindex='0'][role=region][aria-label] > table.admin-table", 6
    assert_select "h1", 1
    assert_select "nav[aria-label='Admin sections'] a", 5
    assert_select "[style]", 0
  end

  test "an admin sees the dashboard with no-store caching and the Admin title" do
    make_admin(users(:onboarded))
    sign_in_as users(:onboarded)
    get "/admin"
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_select "title", text: "Admin - BattleTown", count: 1
    assert_select "h1", "Admin dashboard"
    assert_select ".admin-only table.admin-table", 6
    assert_select "table caption", /Signups per day/
    assert_select "table caption", /Onboarding funnel/
  end

  test "removing the uid from the env takes effect on the next request" do
    make_admin(users(:onboarded))
    sign_in_as users(:onboarded)
    get "/admin"
    assert_response :success

    ENV["ADMIN_HCA_UIDS"] = ""
    get "/admin"
    assert_response :not_found
    ENV.delete("ADMIN_HCA_UIDS")
    get "/admin"
    assert_response :not_found
  end

  test "the admin response contains no PII from the users" do
    users(:new_user).update!(slack_id: "U0SLACKPII")
    make_admin(users(:onboarded))
    sign_in_as users(:onboarded)
    get "/admin"
    assert_response :success
    # The layout shows nothing personal either; check the dashboard content itself.
    content = css_select(".admin-dashboard").to_s
    User.find_each do |user|
      [ user.email, user.display_name, user.slack_id, user.hca_uid ].compact.each do |pii|
        assert_not_includes content, pii
        assert_not_includes response.body, pii
      end
    end
  end

  test "the Admin nav link shows only for admins" do
    sign_in_as users(:onboarded)
    get "/dashboard"
    assert_select "a[href='/admin']", 0
    assert_select ".admin-only", 0

    make_admin(users(:onboarded))
    get "/dashboard"
    assert_select ".site-header .admin-only a[href='/admin']", text: "Admin", count: 1
  end

  test "the Admin nav link is absent for signed-out visitors" do
    make_admin(users(:onboarded))
    get "/"
    assert_select "a[href='/admin']", 0
  end

  test "the admin area is read-only: writes are 404 or 405" do
    make_admin(users(:onboarded))
    sign_in_as users(:onboarded)
    %i[post patch put delete].each do |verb|
      send(verb, "/admin")
      assert_includes [ 404, 405 ], response.status, "#{verb.upcase} /admin"
      send(verb, "/admin/anything")
      assert_includes [ 404, 405 ], response.status, "#{verb.upcase} /admin/anything"
    end
  end

  test "nothing else under /admin exists" do
    make_admin(users(:onboarded))
    sign_in_as users(:onboarded)
    get "/admin/users"
    assert_response :not_found
  end

  test "admin is never a referral slug, so /admin is not swallowed by the referral catch-all" do
    assert_nil Referral.find("admin")
    assert_not_includes Referral.all.map(&:slug), "admin"
    assert_not_includes ReferralSource.keys, "admin"
    assert_equal({ controller: "admin/dashboard", action: "show" }, Rails.application.routes.recognize_path("/admin"))
    assert_equal "referrals", Rails.application.routes.recognize_path("/haven")[:controller]
  end
end
