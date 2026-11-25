require "test_helper"
require_relative "../../support/bosses_helper"
require_relative "../../support/dev_simulator_test_support"

class DevSimulatorShipTest < ActiveSupport::TestCase
  include DevSimulatorTestSupport

  setup do
    local_database!
    @boss = make_current_boss
    @random = Random.new(7)
  end

  teardown { restore_database_host! }

  def players!(count) = DevSimulator::Players.call(count: count, today: utc_today, random: @random)

  def ship!(**args) = DevSimulator::Ship.call(today: utc_today, random: @random, **args)

  test "a ship raises the boss's damage by exactly its seconds, through a real submitted ship" do
    players!(1)
    assert_equal 0, Bosses::Damage.for(@boss)

    result = ship!(mode: "all", hours_min: 2, hours_max: 2)

    assert_equal 1, result.shipped
    assert_equal 2 * HOUR, result.seconds
    assert_equal 2 * HOUR, Bosses::Damage.for(@boss)
    ship = ::Ship.find_by!(user: DevSimulator.players.first)
    assert ship.status_submitted?
    assert_equal 2 * HOUR, ship.coded_seconds
    assert_equal 2 * HOUR, HourEntry.where(user_id: ship.user_id, hackatime_project: ship.hackatime_projects).sum(:seconds)
  end

  test "every ship is counted once, and the damage is the sum of what was shipped" do
    players!(4)

    result = ship!(mode: "all", hours_min: 1, hours_max: 3)

    assert_equal 4, result.shipped
    assert_equal result.seconds, Bosses::Damage.for(@boss)
    assert_equal 4, ::Ship.where(user: DevSimulator.players).count
  end

  test "enough ships beat the boss: it falls once, through the same check a real submit runs" do
    Boss.delete_all
    boss = make_boss(starts_on: friday_on_or_before(utc_today), hp_seconds: 10 * HOUR)
    players!(6)
    assert_nil boss.reload.defeated_at

    ship!(mode: "all", hours_min: 2, hours_max: 2)

    assert_operator Bosses::Damage.for(boss), :>=, 10 * HOUR
    assert_not_nil boss.reload.defeated_at
    first_defeat = boss.defeated_at
    ship!(mode: "all", hours_min: 2, hours_max: 2)
    assert_equal first_defeat.to_i, boss.reload.defeated_at.to_i
  end

  test "modes: a percent of the players, or a count of them" do
    players!(10)

    assert_equal 3, ship!(mode: "percent", percent: 30, hours_min: 1, hours_max: 1).shipped
    assert_equal 1, ship!(mode: "percent", percent: 1, hours_min: 1, hours_max: 1).players
    assert_equal 2, ship!(mode: "count", count: 2, hours_min: 1, hours_max: 1).shipped
  end

  test "hours per ship stay inside the range, in whole minutes" do
    players!(8)

    ship!(mode: "all", hours_min: 1.5, hours_max: 3)

    ::Ship.where(user: DevSimulator.players).find_each do |ship|
      assert_includes (90 * 60)..(3 * HOUR), ship.coded_seconds
      assert_equal 0, ship.coded_seconds % 60
    end
  end

  test "a player never ships on a project that already has a ship, and runs out after their project slots" do
    players!(1)
    player = DevSimulator.players.first

    Project::MAX_PER_USER.times { ship!(mode: "all", hours_min: 1, hours_max: 1) }
    assert_equal Project::MAX_PER_USER, ::Ship.where(user: player).count
    assert_equal Project::MAX_PER_USER, ::Ship.where(user: player).distinct.count(:project_id)

    result = ship!(mode: "all", hours_min: 1, hours_max: 1)
    assert_equal 0, result.shipped
    assert_equal({ no_project: 1 }, result.skipped)
  end

  test "a big ship lands in full: what the capped days cannot hold is written as adjustments, up to 100 hours" do
    players!(1)
    player = DevSimulator.players.first

    result = ship!(mode: "all", hours_min: 100, hours_max: 100)

    assert_equal 1, result.shipped
    assert_equal 100 * HOUR, result.seconds
    assert_equal 100 * HOUR, Bosses::Damage.for(@boss)
    ship = ::Ship.find_by!(user: player)
    assert_equal 100 * HOUR, ship.coded_seconds
    assert_equal 100 * HOUR, HourEntry.where(user: player, hackatime_project: ship.hackatime_projects).sum(:seconds)
    assert_operator HourEntry.where(user: player, source: "adjustment").count, :>=, 1
    assert HourEntry.where(user: player, source: "adjustment").all? { |entry| entry.seconds <= HourEntry::MAX_SECONDS }
  end

  test "a ship holds all its hours even when days before the project time cutoff would not count" do
    players!(1)
    config = Ships::Config.current.with(project_time_from: utc_today - 1)

    stub_method(Ships::Config, :current, -> { config }) { ship!(mode: "all", hours_min: 40, hours_max: 40) }

    assert_equal 1, ::Ship.count
    ship = ::Ship.first
    assert_equal 40 * HOUR, ship.coded_seconds
    assert_equal 40 * HOUR, Bosses::Damage.for(@boss)
    assert_empty ship.daily_seconds.keys.select { |date| Date.iso8601(date) < utc_today - 1 }
  end

  test "the default hours are 1 to 8" do
    assert_equal [ 1, 8 ], [ DevSimulator::DEFAULT_HOURS_MIN, DevSimulator::DEFAULT_HOURS_MAX ]
    players!(6)

    DevSimulator::Ship.call(mode: "all", today: utc_today, random: @random)

    ::Ship.where(user: DevSimulator.players).find_each { |ship| assert_includes HOUR..(8 * HOUR), ship.coded_seconds }
  end

  test "a player whose recent days are full still ships in full, the hours going in as adjustments" do
    players!(1)
    player = DevSimulator.players.first
    daily_cap = Hours::Config.current.daily_cap_seconds
    (0...Hours::Config.current.max_backfill_days).each do |back|
      room = daily_cap - HourEntry.where(user: player, local_date: utc_today - back).sum(:seconds)
      HourEntry.create!(user: player, local_date: utc_today - back, seconds: room, source: "manual", note: "full", idempotency_key: "full-#{back}") if room.positive?
    end

    result = ship!(mode: "all", hours_min: 1, hours_max: 1)

    assert_equal 1, result.shipped
    assert_equal({}, result.skipped)
    assert_equal HOUR, ::Ship.find_by!(user: player).coded_seconds
    assert_equal HOUR, HourEntry.where(user: player, source: "adjustment").sum(:seconds)
  end

  test "a simulated ship never uses a real user's hours or projects" do
    real = users(:onboarded)
    players!(2)

    ship!(mode: "all", hours_min: 1, hours_max: 2)

    assert_equal 0, ::Ship.where(user: real).count
    assert_equal 0, HourEntry.where(user: real).count
  end

  test "bounds: modes, percent, count and hours are checked" do
    players!(2)

    assert_raises(DevSimulator::Refused) { ship!(mode: "everyone") }
    assert_raises(DevSimulator::Refused) { ship!(mode: "percent", percent: 0) }
    assert_raises(DevSimulator::Refused) { ship!(mode: "percent", percent: 101) }
    assert_raises(DevSimulator::Refused) { ship!(mode: "count", count: 0) }
    assert_raises(DevSimulator::Refused) { ship!(mode: "count", count: 201) }
    assert_raises(DevSimulator::Refused) { ship!(mode: "all", hours_min: 0.5, hours_max: 2) } # under the one hour a ship needs
    assert_raises(DevSimulator::Refused) { ship!(mode: "all", hours_min: 1, hours_max: 101) }
    assert_raises(DevSimulator::Refused) { ship!(mode: "all", hours_min: 101, hours_max: 101) }
    assert_raises(DevSimulator::Refused) { ship!(mode: "all", hours_min: 3, hours_max: 2) }
    assert_raises(DevSimulator::Refused) { ship!(mode: "all", hours_min: "lots", hours_max: 2) }
    assert_equal 0, ::Ship.count
  end

  test "refuses with nobody to ship, and on a database that is not local" do
    error = assert_raises(DevSimulator::Refused) { ship!(mode: "all") }
    assert_match(/No players yet: create some first/, error.message)

    players!(1)
    DevSimulator.define_singleton_method(:effective_host) { "db.example.com" }
    assert_raises(DevSimulator::Refused) { ship!(mode: "all") }
    assert_equal 0, ::Ship.count
  end
end
