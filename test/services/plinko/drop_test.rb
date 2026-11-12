require "test_helper"
require_relative "../../support/plinko_helper"

# Dropping uses a Postgres advisory lock, so the concurrency test needs real committed rows and real connections.
class PlinkoDropTest < ActiveSupport::TestCase
  include PlinkoHelper

  self.use_transactional_tests = false

  NOW = Time.utc(2026, 11, 10, 15)

  setup do
    @user = User.create!(hca_uid: "plinko-drop-#{SecureRandom.hex(4)}", display_name: "Dropper", time_zone: "UTC")
    @user.update_columns(created_at: Time.utc(2026, 1, 1), signed_up_on: Date.new(2026, 1, 1))
  end

  teardown do
    PlinkoDrop.where(user_id: @user.id).delete_all
    HourEntry.where(user_id: @user.id).delete_all
    @user.delete
  end

  def key = SecureRandom.hex(12)

  test "no ball means no drop and no row" do
    assert_raises(Plinko::Drop::NoBalls) { Plinko::Drop.call(user: @user, idempotency_key: key, now: NOW) }
    assert_equal 0, PlinkoDrop.where(user_id: @user.id).count
  end

  test "a drop stores the slot, points and seed, and the route replays from the seed" do
    code_on(@user, Date.new(2026, 11, 10), minutes(5))
    result = Plinko::Drop.call(user: @user, idempotency_key: key, now: NOW, seed: 42)
    board = Plinko::Board.current

    assert_not result.replayed
    assert_equal board.walk(42), result.path
    assert_equal board.slot_for(result.path), result.drop.slot
    assert_equal board.points_for(result.drop.slot), result.drop.points
    assert_equal 42, result.drop.seed
    assert_equal Date.new(2026, 11, 10), result.drop.local_date
    assert_equal result.path, result.drop.path
    assert_equal 0, balls_for(@user, NOW).available
  end

  test "the same key twice drops one ball and returns the same result" do
    code_on(@user, Date.new(2026, 11, 10), minutes(10))
    shared = key
    first = Plinko::Drop.call(user: @user, idempotency_key: shared, now: NOW)
    second = Plinko::Drop.call(user: @user, idempotency_key: shared, now: NOW)

    assert second.replayed
    assert_equal first.drop.id, second.drop.id
    assert_equal first.path, second.path
    assert_equal 1, PlinkoDrop.where(user_id: @user.id).count
    assert_equal 1, balls_for(@user, NOW).available, "the second ball is still there"
  end

  test "a replay is allowed even when no ball is left" do
    code_on(@user, Date.new(2026, 11, 10), minutes(5))
    shared = key
    Plinko::Drop.call(user: @user, idempotency_key: shared, now: NOW)
    assert Plinko::Drop.call(user: @user, idempotency_key: shared, now: NOW).replayed
  end

  test "keys that are missing or malformed are refused" do
    code_on(@user, Date.new(2026, 11, 10), minutes(5))
    [ nil, "", "short", "has spaces in it!!", "x" * 65 ].each do |bad|
      assert_raises(Plinko::Drop::InvalidKey) { Plinko::Drop.call(user: @user, idempotency_key: bad, now: NOW) }
    end
    assert_equal 0, PlinkoDrop.where(user_id: @user.id).count
  end

  test "two simultaneous drops with one ball: exactly one succeeds" do
    code_on(@user, Date.new(2026, 11, 10), minutes(5))
    outcomes = Array.new(2) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Plinko::Drop.call(user: @user, idempotency_key: key, now: NOW)
          :dropped
        rescue Plinko::Drop::NoBalls
          :no_balls
        end
      end
    end.map(&:value)

    assert_equal %i[dropped no_balls], outcomes.sort
    assert_equal 1, PlinkoDrop.where(user_id: @user.id).count
  end

  test "four simultaneous drops with two balls: exactly two succeed" do
    code_on(@user, Date.new(2026, 11, 10), minutes(10))
    outcomes = Array.new(4) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Plinko::Drop.call(user: @user, idempotency_key: key, now: NOW)
          :dropped
        rescue Plinko::Drop::NoBalls
          :no_balls
        end
      end
    end.map(&:value)

    assert_equal 2, outcomes.count(:dropped)
    assert_equal 2, PlinkoDrop.where(user_id: @user.id).count
  end

  test "dropping never writes the coins ledger" do
    code_on(@user, Date.new(2026, 11, 10), minutes(10))
    assert_no_difference -> { CoinTransaction.count } do
      2.times { Plinko::Drop.call(user: @user, idempotency_key: key, now: NOW) }
    end
  end

  test "a drop row cannot be changed afterwards" do
    code_on(@user, Date.new(2026, 11, 10), minutes(5))
    drop = Plinko::Drop.call(user: @user, idempotency_key: key, now: NOW).drop
    assert_raises(ActiveRecord::ReadOnlyRecord) { drop.update!(points: 99_999) }
  end
end
