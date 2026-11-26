require "test_helper"
require_relative "../../support/bosses_helper"
require_relative "../../support/dev_simulator_test_support"

class DevSimulatorPlayersTest < ActiveSupport::TestCase
  include DevSimulatorTestSupport

  setup { local_database! }
  teardown { restore_database_host! }

  test "makes marked, onboarded players with a prize, an active project and time coded today" do
    result = DevSimulator::Players.call(count: 5, today: utc_today)

    assert_equal 5, result.created
    assert_equal 5, DevSimulator.players.count
    DevSimulator.players.find_each do |player|
      assert player.hca_uid.start_with?("sim!")
      assert_match(/\ASim \w+ \d+\z/, player.display_name)
      assert player.onboarded?
      assert_nil player.email
      assert_nil player.slack_id
      assert_includes Prize.keys, player.prize_key
      assert_includes DevSimulator::Players::TIME_ZONES, player.time_zone
      assert player.signed_up_on <= utc_today - 29
      assert player.active_project
      assert_equal 1, player.active_project.hackatime_links.count
      assert_operator HourEntry.where(user: player, local_date: utc_today).sum(:seconds), :>=, 15 * 60
    end
    assert_equal 5, Hours::Totals.active_user_count(utc_today)
  end

  test "players have a public profile with a made-up name and address, so their circle on the stage is a link" do
    DevSimulator::Players.call(count: 12, today: utc_today)

    DevSimulator.players.find_each do |player|
      assert_not_respond_to player, :profile_visible?
      assert_equal player.profile_name, player.public_name
      assert_match PublicProfile::NAME_FORMAT, player.profile_name
      assert_no_match(/\bSim\b/, player.profile_name)
      assert_match PublicProfile::SLUG_FORMAT, player.public_slug
      assert_nil player.email
    end
    assert_equal 12, DevSimulator.players.distinct.pluck(:public_slug).size
    assert_equal 12, DevSimulator.players.distinct.pluck(:profile_name).size
  end

  test "players look real: a believable first name or handle and their own picture, through the same pipeline as a Slack picture" do
    DevSimulator::Players.call(count: 20, today: utc_today)

    names = DevSimulator.players.pluck(:profile_name)
    assert_equal 20, names.uniq.size
    assert_equal DevSimulator::Looks.name_for(1), DevSimulator.players.find_by!(hca_uid: "sim!1").profile_name
    profiles = SlackProfile.where(user_id: DevSimulator.players.select(:id))
    assert_equal 20, profiles.count
    assert_equal 20, profiles.distinct.pluck(:picture_sha256).size, "distinct pictures"
    profiles.without_picture.each { |profile| assert_equal [ "ok", true, true ], [ profile.status, profile.use_name, profile.use_picture ] }
    sample = SlackProfile.where(user_id: DevSimulator.players.select(:id)).first
    image = Vips::Image.webpload_buffer(sample.picture)
    assert_equal [ 128, 128 ], [ image.width, image.height ]

    DevSimulator::Players.call(count: 20, today: utc_today)
    assert_equal 20, SlackProfile.where(user_id: DevSimulator.players.select(:id)).count, "a second call doubles nothing"
    snapshot = Bosses::Fighters.call(make_current_boss)
    assert snapshot.circles.all? { |circle| circle.avatar_url.present? }
  end

  test "simulated players are still excluded from analytics and the simulator reset removes their pictures too" do
    DevSimulator::Players.call(count: 3, today: utc_today)
    player = DevSimulator.players.first
    assert Analytics.excluded?(player)
    assert_no_difference -> { AnalyticsEvent.count } do
      Analytics.track(:slack_profile_fetched, user: player, picture: true)
    end

    DevSimulator::Reset.call(today: utc_today)
    assert_equal 0, SlackProfile.where(user_id: nil).count
    assert_equal 0, SlackProfile.count
  end

  test "the minutes are varied: some under the daily goal, some over it, some a lot, and every one counts as a fighter" do
    DevSimulator::Players.call(count: 10, today: utc_today)

    minutes = DevSimulator.players.map { |player| HourEntry.where(user: player).sum(:seconds) / 60 }
    goal = Game::Config.current.goal_seconds / 60
    assert_operator minutes.min, :>=, 15
    assert(minutes.any? { |value| value < goal / 2 }, "a small one")
    assert(minutes.any? { |value| value >= goal / 2 && value < goal }, "under the goal")
    assert(minutes.any? { |value| value >= goal && value < goal * 2 }, "over it")
    assert(minutes.any? { |value| value >= goal * 4 }, "a lot")

    snapshot = Bosses::Fighters.call(make_current_boss)
    assert_equal 10, snapshot.total, "their entries are recorded now, so they are fighters in the last 24 hours"
    assert_equal (1..5).to_a, DevSimulator.players.map { |player| Bosses::Fighters.size_for(HourEntry.where(user: player).sum(:seconds)) }.uniq.sort
    assert_equal %i[code idle], snapshot.circles.map(&:tier).uniq.sort
    assert snapshot.circles.all? { |circle| circle.path && circle.name }
  end

  test "ledger rows are tagged and written through the credit service (manual source)" do
    DevSimulator::Players.call(count: 2, today: utc_today)

    entries = HourEntry.where(user: DevSimulator.players)
    assert_equal 2, entries.count
    assert entries.all? { |entry| entry.source == "manual" && entry.created_by == "dev:sim" }
  end

  test "running it again does not double anything, and asking for more only adds the missing ones" do
    DevSimulator::Players.call(count: 3, today: utc_today)
    names = DevSimulator.players.order(:id).pluck(:display_name)
    minutes = HourEntry.where(user: DevSimulator.players).sum(:seconds)

    again = DevSimulator::Players.call(count: 3, today: utc_today)
    assert_equal [ 0, 3, 0 ], [ again.created, again.existing, again.credited ]
    assert_equal 3, DevSimulator.players.count
    assert_equal minutes, HourEntry.where(user: DevSimulator.players).sum(:seconds)

    more = DevSimulator::Players.call(count: 5, today: utc_today)
    assert_equal [ 2, 3 ], [ more.created, more.existing ]
    assert_equal 5, DevSimulator.players.count
    assert_equal names, DevSimulator.players.order(:id).first(3).pluck(:display_name)
  end

  test "a new day gets fresh minutes for the players that already exist" do
    DevSimulator::Players.call(count: 2, today: utc_today - 1)
    result = DevSimulator::Players.call(count: 2, today: utc_today)

    assert_equal [ 0, 2, 2 ], [ result.created, result.existing, result.credited ]
  end

  test "never touches a real user" do
    real = users(:onboarded)
    before = real.reload.attributes

    DevSimulator::Players.call(count: 3, today: utc_today)

    assert_equal before, real.reload.attributes
    assert_equal 0, HourEntry.where(user: real).count
  end

  test "bounds: 1 to 200 players, whole numbers only" do
    [ 0, -1, 201, "abc", nil, 1.5 ].each do |bad|
      error = assert_raises(DevSimulator::Refused, bad.inspect) { DevSimulator::Players.call(count: bad, today: utc_today) }
      assert_match(/players must be a whole number from 1 to 200/, error.message)
    end
    assert_equal 0, DevSimulator.players.count
    assert_equal 3, DevSimulator::Players.call(count: "3", today: utc_today).created
  end

  test "refuses to pass 500 simulated players in all" do
    now = Time.current
    rows = (1..499).map { |n| { hca_uid: "sim!#{1000 + n}", display_name: "Sim #{n}", public_slug: SecureRandom.alphanumeric(11).downcase, signed_up_on: utc_today, created_at: now, updated_at: now } }
    User.insert_all!(rows)

    error = assert_raises(DevSimulator::Refused) { DevSimulator::Players.call(count: 2, today: utc_today) }
    assert_match(/At most 500/, error.message)
    assert_equal 499, DevSimulator.players.count
  end

  test "refuses when the database is not on this machine" do
    DevSimulator.define_singleton_method(:effective_host) { "db.example.com" }

    error = assert_raises(DevSimulator::Refused) { DevSimulator::Players.call(count: 2, today: utc_today) }
    assert_match(/not on this machine|only writes to a database on this machine/, error.message)
    assert_equal 0, DevSimulator.players.count
  end
end
