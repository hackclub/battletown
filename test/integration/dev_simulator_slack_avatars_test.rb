require "test_helper"
require_relative "../support/dev_simulator_test_support"
require_relative "../support/dev_slack_manifest_support"

# Simulated players dressed from a (fake) local Slack manifest are served like any real player: the avatar route and the fighters JSON.
class DevSimulatorSlackAvatarsTest < ActionDispatch::IntegrationTest
  include DevSimulatorTestSupport
  include DevSlackManifestSupport

  setup do
    local_database!
    use_fake_manifest(%w[Zorblax Quimby Fennimore])
    @today = Time.current.utc.to_date
    @viewer = users(:onboarded)
    @viewer.update_columns(created_at: (@today - 30).in_time_zone("UTC"), signed_up_on: @today - 30)
    make_current_boss
    DevSimulator::Players.call(count: 4, today: @today)
  end

  teardown do
    restore_database_host!
    drop_fake_manifest
    reset_omniauth
  end

  test "the avatar route serves each manifest picture as WebP, and the fighters JSON names and pictures them" do
    sign_in_as @viewer
    real = DevSimulator.players.order(:id).first(3)
    real.each do |player|
      get player_avatar_path(player.public_slug)
      assert_response :success
      assert_equal "image/webp", response.media_type
      assert_equal SlackProfile.where(user_id: player.id).pick(:picture_sha256), Digest::SHA256.hexdigest(response.body)
    end

    get boss_fighters_path
    fighters = JSON.parse(response.body)["fighters"]
    by_title = fighters.index_by { |fighter| fighter["title"] }
    %w[Zorblax Quimby Fennimore].each { |name| assert_match %r{\A/players/[^/]+/avatar\?v=\h{10}\z}, by_title[name]["avatar_url"] }
    assert_equal 4, fighters.size
    assert(fighters.all? { |fighter| fighter["avatar_url"].present? }, "the fourth player has a generated picture")
  end
end
