require "test_helper"
require_relative "../../support/bosses_helper"
require_relative "../../support/dev_simulator_test_support"
require_relative "../../support/dev_slack_manifest_support"

# Simulated players wearing the names and pictures of a (fake) local Slack manifest.
class DevSimulatorSlackPlayersTest < ActiveSupport::TestCase
  include DevSimulatorTestSupport
  include DevSlackManifestSupport
  include ActiveJob::TestHelper

  setup { local_database! }
  teardown do
    restore_database_host!
    drop_fake_manifest
  end

  def players = DevSimulator.players.order(:id)

  test "players wear the manifest in order: a profile with the name, a slug and the picture, never a Slack id" do
    use_fake_manifest(%w[Zorblax Quimby Fennimore])

    DevSimulator::Players.call(count: 3, today: utc_today)

    assert_equal %w[Zorblax Quimby Fennimore], players.pluck(:profile_name)
    players.each do |player|
      assert_equal player.profile_name, player.public_name
      assert_match PublicProfile::SLUG_FORMAT, player.public_slug
      assert_nil player.slack_id
      assert_nil player.email
      profile = SlackProfile.for(player)
      assert_equal player.profile_name, profile.display_name
      assert_equal "ok", profile.status
      assert profile.use_name && profile.use_picture && profile.picture?
    end
    assert_equal 3, players.pluck(:public_slug).uniq.size
    assert_equal 3, SlackProfile.where(user_id: players.ids).distinct.count(:picture_sha256), "each has their own picture"
  end

  test "more players than entries: the rest keep generated looks and no real name appears twice" do
    use_fake_manifest(%w[Maya Kai])

    DevSimulator::Players.call(count: 6, today: utc_today)

    names = players.pluck(:profile_name)
    assert_equal %w[Maya Kai], names.first(2)
    assert_equal 6, names.map(&:downcase).uniq.size
    assert_equal 1, names.count { |name| name.casecmp?("Maya") }, "the generated name that was Maya is changed"
    assert_equal 1, names.count { |name| name.casecmp?("Kai") }
    assert(players.all? { |player| SlackProfile.for(player).picture? })
    assert_equal [ "Maya", "Kai" ], SlackProfile.where(user_id: players.first(2).map(&:id)).order(:user_id).pluck(:display_name)
  end

  test "without a manifest, or with a malformed one, players look generated as before" do
    use_empty_manifest_dir
    DevSimulator::Players.call(count: 3, today: utc_today)
    assert_equal (1..3).map { |counter| DevSimulator::Looks.name_for(counter) }, players.pluck(:profile_name)

    File.write(File.join(@dev_slack_dir, "manifest.json"), "{ this is not json")
    DevSimulator::Players.call(count: 4, today: utc_today)
    assert_equal (1..4).map { |counter| DevSimulator::Looks.name_for(counter) }, players.pluck(:profile_name)
    assert(players.all? { |player| SlackProfile.for(player).picture? })
  end

  test "an entry whose picture is not an image falls back to the generated look for that player" do
    use_fake_manifest(%w[Zorblax Quimby])
    File.binwrite(File.join(@dev_slack_dir, "player-02.webp"), "this is plainly not an image")

    DevSimulator::Players.call(count: 2, today: utc_today)

    assert_equal "Zorblax", players.first.profile_name
    assert_equal DevSimulator::Looks.name_for(2), players.second.profile_name
    assert SlackProfile.for(players.second).picture?
  end

  test "players that exist already are moved onto the manifest by the next run, and apply_all does the same for all of them (idempotent)" do
    use_empty_manifest_dir
    DevSimulator::Players.call(count: 4, today: utc_today)
    generated = players.pluck(:profile_name)

    drop_fake_manifest
    use_fake_manifest(%w[Zorblax Quimby])

    updated = DevSimulator::Looks.apply_all
    assert_equal 2, updated, "the two with entries change; the generated ones are untouched"
    assert_equal %w[Zorblax Quimby], players.pluck(:profile_name).first(2)
    assert_equal generated.last(2), players.pluck(:profile_name).last(2)
    assert_equal 0, DevSimulator::Looks.apply_all, "a second run changes nothing"
    assert_equal 4, DevSimulator::Looks.apply_all(force: true)
    assert_equal 4, SlackProfile.where(user_id: players.ids).count
  end

  test "when the manifest goes away, existing players keep what they have (a reset clears them)" do
    use_fake_manifest(%w[Zorblax])
    DevSimulator::Players.call(count: 2, today: utc_today)
    FileUtils.rm_f(File.join(@dev_slack_dir, "manifest.json"))

    assert_equal 0, DevSimulator::Looks.apply_all
    assert_equal [ "Zorblax", DevSimulator::Looks.name_for(2) ], players.pluck(:profile_name)
    assert_equal 2, DevSimulator::Players.call(count: 2, today: utc_today).existing
  end

  test "a second run does not touch the pictures that already look right" do
    use_fake_manifest(%w[Zorblax Quimby])
    DevSimulator::Players.call(count: 2, today: utc_today)
    stamps = SlackProfile.where(user_id: players.ids).order(:id).pluck(:updated_at)

    DevSimulator::Players.call(count: 2, today: utc_today)

    assert_equal stamps, SlackProfile.where(user_id: players.ids).order(:id).pluck(:updated_at)
  end

  test "the avatars are served by the circles: fighters have an avatar url and a name, and hover shows the manifest name" do
    use_fake_manifest(%w[Zorblax Quimby Fennimore])
    DevSimulator::Players.call(count: 3, today: utc_today)

    snapshot = Bosses::Fighters.call(make_current_boss)
    assert_equal 3, snapshot.circles.size
    assert_equal %w[Fennimore Quimby Zorblax], snapshot.circles.map(&:name).sort
    assert snapshot.circles.all? { |circle| circle.avatar_url.present? }
  end

  test "the refresh machinery never reaches simulated players: no Slack id, so not eligible, not due, nothing queued" do
    use_fake_manifest
    DevSimulator::Players.call(count: 3, today: utc_today)
    real = make_player("realone", name: "Realone")
    SlackProfile.create!(user: real, use_name: true, use_picture: true) # chose "Use my Slack name and picture"

    ENV["SLACK_BOT_TOKEN"] = "xoxb-test-not-real"
    players.each do |player|
      assert_not SlackProfiles.eligible?(player)
      assert_equal :skipped, SlackProfiles::Refresh.call(player, client: Object.new).status
    end
    assert_not_includes SlackProfiles.due_scope.pluck(:id), players.first.id
    assert_equal [ real.id ], SlackProfiles.due_scope.where(id: [ real.id, *players.ids ]).pluck(:id)
    assert_no_enqueued_jobs { players.each { |player| SlackProfiles.refresh_later(player) } }
  ensure
    ENV.delete("SLACK_BOT_TOKEN")
  end
end
