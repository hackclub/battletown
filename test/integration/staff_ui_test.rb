require "test_helper"

class StaffUiTest < ActionDispatch::IntegrationTest
  def in_env(name)
    original = Rails.env
    Rails.env = name
    yield
  ensure
    Rails.env = original
  end

  test "landing page shows exactly one Dev login in development, in the header, as a green dev-only chip with a CSRF form" do
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    in_env("development") { get "/" }
    assert_response :success

    assert_select "button", text: "Dev login", count: 1
    assert_select "form[action='/dev_login']", 1
    assert_select ".site-header .dev-only form[action='/dev_login'][method='post'][data-turbo='false']", 1 do
      assert_select "input[name='authenticity_token'][type='hidden']", 1 do |tokens|
        assert tokens.first["value"].present?
      end
      assert_select "button", "Dev login"
    end
    assert_select ".landing-hero form[action='/dev_login']", 0
    assert_select ".admin-only", 0
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  test "Dev login is absent outside development" do
    get "/"
    assert_response :success
    assert_select "form[action='/dev_login']", 0
    assert_select ".dev-only", 0
    assert_select "button", text: "Dev login", count: 0
  end

  test "Dev login is in the header of every page, so other pages show it once too" do
    in_env("development") do
      get "/privacy"
      assert_select "button", text: "Dev login", count: 1
    end
  end

  test "no admin-only UI for signed-out visitors" do
    get "/"
    assert_select ".admin-only", 0
  end

  test "the staff stylesheet only strips button chrome from small staff chips, never from whole staff pages" do
    css = Rails.root.join("app/assets/stylesheets/staff.css").read
    assert_no_match(/\.(dev|admin)-only\.(dev|admin)-only \.btn/, css)
    assert_match(/\.dev-only--unlabelled\.dev-only--unlabelled \.btn\.btn/, css)
    assert_match(/\.admin-only--unlabelled\.admin-only--unlabelled \.btn\.btn/, css)
  end
end
