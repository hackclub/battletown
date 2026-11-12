require "test_helper"
require_relative "../support/bosses_helper"

class AdminBossesTest < ActionDispatch::IntegrationTest
  include BossesHelper

  setup do
    OmniAuth.config.test_mode = true
    @original_env = ENV["ADMIN_HCA_UIDS"]
    @detailed = Rails.application.env_config["action_dispatch.show_detailed_exceptions"]
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = false
    @boss = make_boss(starts_on: Date.new(2026, 11, 20), name: "Boss 2", hp_seconds: 500 * HOUR)
    @past = make_boss(starts_on: Date.new(2026, 11, 6), name: "Boss 0")
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

  def make_admin(user) = ENV["ADMIN_HCA_UIDS"] = user.hca_uid

  def update_params(**boss) = { boss: boss }

  test "signed-out visitors get a 404 on every bosses route" do
    get "/admin/bosses"
    assert_response :not_found
    get "/admin/bosses/#{@boss.id}/edit"
    assert_response :not_found
    patch "/admin/bosses/#{@boss.id}", params: update_params(name: "Hacked")
    assert_response :not_found
    assert_equal "Boss 2", @boss.reload.name
  end

  test "non-admins get the same 404 and cannot change a boss" do
    sign_in_as users(:onboarded)
    missing = (get("/definitely-not-a-page") && response.body)

    get "/admin/bosses"
    assert_response :not_found
    assert_equal missing, response.body
    get "/admin/bosses/#{@boss.id}/edit"
    assert_response :not_found
    patch "/admin/bosses/#{@boss.id}", params: update_params(name: "Hacked", hp_hours: 1)
    assert_response :not_found
    @boss.reload
    assert_equal "Boss 2", @boss.name
    assert_equal 500 * HOUR, @boss.hp_seconds
  end

  test "an admin sees the list: aggregate numbers, no names, no-store" do
    users(:new_user).update!(display_name: "Secret Person")
    add_hours(users(:new_user), Date.new(2026, 11, 20), 2 * HOUR)
    make_admin(users(:onboarded))
    sign_in_as users(:onboarded)

    travel_to Time.utc(2026, 11, 21, 12) do
      get "/admin/bosses"
    end

    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_select "title", text: "Admin bosses - BattleTown"
    assert_select ".admin-only table.admin-table tbody tr", 2
    assert_select "tbody tr:first-child th", "Boss 0"
    assert_select "tbody tr", text: /Boss 2.*500.*2\.0.*In progress/m
    assert_select "a[href=?]", "/admin/bosses/#{@boss.id}/edit", 1
    assert_not_includes response.body, "Secret Person"
    assert_not_includes response.body, users(:new_user).email
  end

  test "the admin dashboard links to the bosses" do
    make_admin(users(:onboarded))
    sign_in_as users(:onboarded)
    get "/admin"
    assert_select ".admin-only a[href='/admin/bosses']", "Weekly bosses"
  end

  test "an admin edits name, art and health before the boss starts" do
    make_admin(users(:onboarded))
    sign_in_as users(:onboarded)

    travel_to Time.utc(2026, 11, 12, 12) do
      get "/admin/bosses/#{@boss.id}/edit"
      assert_response :success
      assert_select "form input[name='boss[hp_hours]']:not([disabled])", 1
      assert_select "form input[name='boss[starts_on]']", 0
      assert_select "form input[name='boss[ends_on]']", 0

      patch "/admin/bosses/#{@boss.id}", params: update_params(name: "The Linter", art_key: "placeholder", hp_hours: "120")
      assert_redirected_to "/admin/bosses"
    end

    @boss.reload
    assert_equal "The Linter", @boss.name
    assert_equal 120 * HOUR, @boss.hp_seconds
  end

  test "health is locked once the boss has started, but the name can still change" do
    make_admin(users(:onboarded))
    sign_in_as users(:onboarded)

    travel_to Time.utc(2026, 11, 21, 12) do
      get "/admin/bosses/#{@boss.id}/edit"
      assert_select "input[name='boss[hp_hours]'][disabled]", 1
      assert_select "form", text: /Locked/

      patch "/admin/bosses/#{@boss.id}", params: update_params(name: "Renamed", hp_hours: "1")
      assert_response :unprocessable_content
      assert_select ".admin-form__errors", text: /can't change once the boss has started/
      assert_equal 500 * HOUR, @boss.reload.hp_seconds
      assert_equal "Boss 2", @boss.name, "nothing is saved when any field is refused"

      patch "/admin/bosses/#{@boss.id}", params: update_params(name: "Renamed")
      assert_redirected_to "/admin/bosses"
    end
    assert_equal "Renamed", @boss.reload.name
    assert_equal 500 * HOUR, @boss.hp_seconds
  end

  test "dates and defeat cannot be changed through the form" do
    make_admin(users(:onboarded))
    sign_in_as users(:onboarded)
    travel_to Time.utc(2026, 11, 12, 12) do
      patch "/admin/bosses/#{@boss.id}", params: { boss: { name: "Same", starts_on: "2026-12-01", ends_on: "2026-12-07", defeated_at: Time.current.iso8601, id: 999 } }
    end
    @boss.reload
    assert_equal Date.new(2026, 11, 20), @boss.starts_on
    assert_equal Date.new(2026, 11, 26), @boss.ends_on
    assert_nil @boss.defeated_at
  end

  test "invalid input is refused with a message" do
    make_admin(users(:onboarded))
    sign_in_as users(:onboarded)
    travel_to Time.utc(2026, 11, 12, 12) do
      patch "/admin/bosses/#{@boss.id}", params: update_params(name: "", art_key: "../etc/passwd", hp_hours: "0")
      assert_response :unprocessable_content
      assert_select ".admin-form__errors li", minimum: 3

      patch "/admin/bosses/#{@boss.id}", params: update_params(hp_hours: "lots")
      assert_response :unprocessable_content
    end
    assert_equal 500 * HOUR, @boss.reload.hp_seconds
  end

  test "an unknown boss id is a 404" do
    make_admin(users(:onboarded))
    sign_in_as users(:onboarded)
    get "/admin/bosses/0/edit"
    assert_response :not_found
  end
end
