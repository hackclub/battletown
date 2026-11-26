require "test_helper"
require_relative "../../support/bosses_helper"
require_relative "../../support/dev_simulator_test_support"

class DevSimulatorStatusTest < ActiveSupport::TestCase
  include DevSimulatorTestSupport

  setup do
    local_database!
    @boss = make_current_boss(hp_seconds: 100 * HOUR)
    @user = users(:onboarded)
  end

  teardown { restore_database_host! }

  def status(**args) = DevSimulator::Status.call(user: @user, today: utc_today, **args)

  test "reads the boss from the same numbers as the dashboard, and the headcounts" do
    DevSimulator::Players.call(count: 4, today: utc_today)
    DevSimulator::Ship.call(mode: "all", today: utc_today, hours_min: 2, hours_max: 2)

    result = status

    boss = result[:boss]
    assert_equal @boss.name, boss[:name]
    assert_equal "in_progress", boss[:state]
    assert_equal 8 * HOUR, boss[:damage_seconds]
    assert_equal Bosses::Presenter.new(user: @user, today: utc_today).health_percent, boss[:health_percent]
    assert_equal "92% left", boss[:health_text]
    assert_equal "about 92 hours to go", boss[:hours_to_go_text]
    assert_equal 4, result[:players]
    assert_equal 4, result[:people_coded]
    assert_equal 4, result[:people_shipped]
    assert_operator result[:simulated_minutes_24h], :>=, 4 * 15
    assert_not_includes boss.keys, :arena_text, "the stage's own controller keeps the arena sentence"
    assert_equal 4, result[:simulated_ships_this_week]
  end

  test "counts only the last 24 hours: people and shippers" do
    DevSimulator::Players.call(count: 3, today: utc_today)
    DevSimulator::Ship.call(mode: "count", count: 1, today: utc_today, hours_min: 2, hours_max: 2)
    HourEntry.where(user: DevSimulator.players).update_all(recorded_at: 25.hours.ago)

    result = status
    assert_equal [ 0, 0 ], [ result[:people_coded], result[:people_shipped] ]
    assert_equal 0, result[:simulated_minutes_24h]
  end

  test "carries the last action's counts and nothing that names a person" do
    DevSimulator::Players.call(count: 2, today: utc_today)

    result = status(last: { shipped: 1 })
    assert_equal({ shipped: 1 }, result[:last])

    text = result.to_json
    assert_not_includes text, "Sim "
    assert_not_includes text, "sim!"
    assert_not_includes text, @user.display_name
  end

  test "with no boss this week there is no boss block, and the counts still work" do
    Boss.delete_all

    result = status

    assert_nil result[:boss]
    assert_equal 0, result[:players]
    assert_equal 0, result[:simulated_ships_this_week]
  end

  test "refuses when the database is not on this machine" do
    DevSimulator.define_singleton_method(:effective_host) { "db.example.com" }

    assert_raises(DevSimulator::Refused) { status }
  end
end
