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
    rows = (1..499).map { |n| { hca_uid: "sim!#{1000 + n}", display_name: "Sim #{n}", signed_up_on: utc_today, created_at: now, updated_at: now } }
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
