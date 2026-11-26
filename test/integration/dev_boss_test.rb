require "test_helper"
require_relative "../support/bosses_helper"
require_relative "../support/ship_images_helper"

class DevBossTest < ActionDispatch::IntegrationTest
  include BossesHelper
  include ShipImagesHelper

  def in_env(name)
    original = Rails.env
    Rails.env = name
    yield
  ensure
    Rails.env = original
  end

  setup do
    @detailed = Rails.application.env_config["action_dispatch.show_detailed_exceptions"]
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = false
  end

  teardown { Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = @detailed }

  def dev_login = in_env("development") { post "/dev_login" }

  test "404 outside development, signed in or not" do
    get "/dev/boss"
    assert_response :not_found

    dev_login
    %w[test production].each do |env|
      in_env(env) do
        get "/dev/boss", params: { state: "defeated" }
        assert_response :not_found, env
      end
    end
  end

  test "signed-out visitors are sent to sign in in development" do
    in_env("development") { get "/dev/boss" }
    assert_redirected_to root_path
  end

  test "shows the real card in a green dev-only frame" do
    # The signed-in user's own day can be a day away from the server's, so the week before is a boss too (a Friday today is a Thursday there).
    this_friday = friday_on_or_before(Date.current)
    make_boss(starts_on: this_friday, name: "Real Boss")
    make_boss(starts_on: this_friday - 7, name: "Real Boss")
    dev_login
    in_env("development") { get "/dev/boss" }

    assert_response :success
    assert_select "section.dev-only", 1
    assert_select "section.boss-card--in-progress h2", "Real Boss"
    assert_select "a[href='/dev/hours']", 1
  end

  test "the real card shows a boss's own picture" do
    this_friday = friday_on_or_before(Date.current)
    [ this_friday, this_friday - 7 ].each do |starts_on|
      boss = make_boss(starts_on: starts_on, name: "Pictured Boss")
      boss.attach_art(ShipImages::Processor.call(upload_file(png_bytes(64, 32)), config: Bosses::ArtConfig.current))
      boss.art_alt = "A pictured boss"
      boss.save!
    end
    dev_login
    in_env("development") { get "/dev/boss" }

    assert_response :success
    assert_select "img.boss-card__art[src^='/bosses/'][alt='A pictured boss']", 1
  end

  test "state and percent params render a made-up boss and write nothing" do
    dev_login
    assert_no_difference [ "Boss.count", "HourEntry.count" ] do
      { "in_progress" => "boss-card--in-progress", "defeated" => "boss-card--defeated", "escaped" => "boss-card--escaped", "none" => "boss-card--none" }.each do |state, css|
        in_env("development") { get "/dev/boss", params: { state: state, percent: "40" } }
        assert_response :success, state
        assert_select "section.#{css}", 1
      end
    end

    in_env("development") { get "/dev/boss", params: { state: "in_progress", percent: "40" } }
    assert_select "progress[value='40']", 1
  end

  test "junk params fall back safely" do
    dev_login
    in_env("development") { get "/dev/boss", params: { state: "<script>", percent: "9999999999999" } }
    assert_response :success
    assert_not_includes response.body, "<script>"
    in_env("development") { get "/dev/boss", params: { state: "in_progress", percent: "abc" } }
    assert_select "progress[value='62']", 1
    in_env("development") { get "/dev/boss", params: { state: "in_progress", percent: "9999" } }
    assert_select "progress[value='100']", 1
  end
end
