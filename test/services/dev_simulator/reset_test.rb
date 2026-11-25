require "test_helper"
require_relative "../../support/bosses_helper"
require_relative "../../support/every_table_rows"
require_relative "../../support/dev_simulator_test_support"

class DevSimulatorResetTest < ActiveSupport::TestCase
  include DevSimulatorTestSupport
  include EveryTableRows

  setup do
    local_database!
    @boss = make_current_boss
  end

  teardown { restore_database_host! }

  test "removes only the simulated players and everything that references them" do
    DevSimulator::Players.call(count: 3, today: utc_today)
    DevSimulator::Ship.call(mode: "all", today: utc_today)
    sim_ids = DevSimulator.players.pluck(:id)
    assert_operator ::Ship.where(user_id: sim_ids).count, :>, 0

    result = DevSimulator::Reset.call(today: utc_today)

    assert_equal 3, result.removed
    assert_equal 0, DevSimulator.players.count
    [ ::Ship, HourEntry, Project, HackatimeLink ].each { |model| assert_equal 0, model.where(user_id: sim_ids).count, model.name }
    assert_equal 0, Bosses::Damage.for(@boss)
  end

  test "a real user's rows are untouched, however many tables they fill" do
    real = user_with_rows_in_every_table
    counts = ActiveRecord::Base.connection.tables.index_with { |table| ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM #{ActiveRecord::Base.connection.quote_table_name(table)}") }
    real_counts = counts.slice("ships", "hour_entries", "projects", "orders", "coin_transactions")

    DevSimulator::Players.call(count: 3, today: utc_today)
    DevSimulator::Ship.call(mode: "all", today: utc_today)
    DevSimulator::Reset.call(today: utc_today)

    assert User.exists?(real.id)
    after = ActiveRecord::Base.connection.tables.index_with { |table| ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM #{ActiveRecord::Base.connection.quote_table_name(table)}") }
    assert_equal counts.except("schema_migrations", "ar_internal_metadata"), after.except("schema_migrations", "ar_internal_metadata")
    assert_equal real_counts, after.slice(*real_counts.keys)
  end

  test "a user whose id only looks similar is not removed" do
    lookalikes = %w[sim ident!sim!1 Sim!1 xsim!1].map { |uid| User.create!(hca_uid: uid, display_name: "Real #{uid}") }
    DevSimulator::Players.call(count: 1, today: utc_today)

    DevSimulator::Reset.call(today: utc_today)

    assert_equal lookalikes.size, User.where(id: lookalikes.map(&:id)).count
  end

  test "the boss stays down after a reset unless asked to be let up again" do
    @boss.update_columns(defeated_at: Time.current)

    DevSimulator::Reset.call(today: utc_today)
    assert_not_nil @boss.reload.defeated_at

    result = DevSimulator::Reset.call(today: utc_today, clear_defeat: true)
    assert_nil @boss.reload.defeated_at
    assert_equal 1, result.cleared_defeat
  end

  test "with nobody to remove it does nothing" do
    result = DevSimulator::Reset.call(today: utc_today)

    assert_equal 0, result.removed
  end

  test "refuses when the database is not on this machine" do
    DevSimulator::Players.call(count: 1, today: utc_today)
    DevSimulator.define_singleton_method(:effective_host) { "10.0.0.5" }

    assert_raises(DevSimulator::Refused) { DevSimulator::Reset.call(today: utc_today) }
    assert_equal 1, DevSimulator.players.count
  end
end
