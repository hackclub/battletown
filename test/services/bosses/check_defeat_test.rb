require "test_helper"
require_relative "../../support/bosses_helper"

class Bosses::CheckDefeatTest < ActiveSupport::TestCase
  include BossesHelper

  setup do
    @user = users(:onboarded)
    @boss = make_boss(hp_seconds: 3_600)
  end

  test "one second short is not defeated, exact HP is" do
    add_hours(@user, FRIDAY, 3_599)
    assert_not Bosses::CheckDefeat.call(@boss)
    assert_nil @boss.reload.defeated_at

    add_hours(@user, FRIDAY + 1, 1)
    assert @boss.reload.defeated?, "the ledger callback records the defeat"
  end

  test "call returns true only the first time" do
    HourEntry.insert_all!([ { user_id: @user.id, local_date: FRIDAY, seconds: 4_000, source: "manual", note: "t", idempotency_key: "bulk" } ])
    assert Bosses::CheckDefeat.call(@boss)
    first = @boss.reload.defeated_at
    assert_not_nil first
    assert_not Bosses::CheckDefeat.call(@boss)
    assert_equal first, @boss.reload.defeated_at
  end

  test "a ledger credit that crosses the health sets defeated_at through the callback" do
    # Hours::Credit only backfills a few days, so credit on the boss's first day.
    result = travel_to(Time.utc(2026, 11, 13, 12)) do
      Hours::Credit.call(user: @user, seconds: 3_600, source: "manual", note: "hit", local_date: FRIDAY, idempotency_key: "cross")
    end
    assert result.created?
    assert @boss.reload.defeated?
  end

  test "an entry dated outside the boss week does not touch it" do
    add_hours(@user, FRIDAY - 1, 9_999)
    add_hours(@user, THURSDAY + 1, 9_999)
    assert_nil @boss.reload.defeated_at
  end

  test "damage from other users counts, and they all feed the same boss" do
    add_hours(@user, FRIDAY, 2_000)
    assert_nil @boss.reload.defeated_at
    add_hours(users(:new_user), FRIDAY + 1, 1_600)
    assert @boss.reload.defeated?
  end

  test "defeated_at is never cleared when an adjustment lowers the damage" do
    add_hours(@user, FRIDAY, 5_000)
    at = @boss.reload.defeated_at
    assert_not_nil at

    add_hours(@user, FRIDAY, -4_000, source: "adjustment")
    assert_equal 1_000, Bosses::Damage.for(@boss)
    assert_not Bosses::CheckDefeat.call(@boss)
    assert_equal at, @boss.reload.defeated_at
  end

  test "an already defeated boss is not re-checked or moved by later entries" do
    add_hours(@user, FRIDAY, 5_000)
    at = @boss.reload.defeated_at
    add_hours(@user, FRIDAY + 1, 5_000)
    assert_equal at, @boss.reload.defeated_at
  end

  test "a failure in the check never fails the ledger write" do
    original = Bosses::CheckDefeat.method(:call)
    Bosses::CheckDefeat.define_singleton_method(:call) { |_boss| raise "boom" }
    begin
      assert_difference "HourEntry.count", 1 do
        add_hours(@user, FRIDAY, 5_000)
      end
    ensure
      Bosses::CheckDefeat.define_singleton_method(:call, original)
    end
    assert_nil @boss.reload.defeated_at
    assert Bosses::CheckDefeat.call(@boss), "the next check catches up"
  end

  test "batched defers the checks to one per boss when the block ends" do
    checked = []
    original = Bosses::CheckDefeat.method(:call)
    Bosses::CheckDefeat.define_singleton_method(:call) do |boss|
      checked << boss.id
      original.call(boss)
    end
    begin
      Bosses::CheckDefeat.batched do
        add_hours(@user, FRIDAY, 2_000)
        add_hours(@user, FRIDAY + 1, 2_000)
        Bosses::CheckDefeat.batched { add_hours(@user, FRIDAY + 2, 1) }
        assert_empty checked, "nothing is summed inside the batch"
        assert_nil @boss.reload.defeated_at
      end
    ensure
      Bosses::CheckDefeat.define_singleton_method(:call, original)
    end
    assert_equal [ @boss.id ], checked
    assert @boss.reload.defeated?
  end

  test "batched still checks when the block raises, and only the bosses covering the noted dates" do
    other = make_boss(starts_on: FRIDAY + 7, hp_seconds: 1)
    add_hours(@user, FRIDAY + 7, 5) # defeats the other boss straight away (no batch)
    later = make_boss(starts_on: FRIDAY + 14, hp_seconds: 1)
    HourEntry.insert_all!([ { user_id: @user.id, local_date: FRIDAY + 14, seconds: 10, source: "manual", note: "t", idempotency_key: "silent" } ])

    assert_raises(RuntimeError) do
      Bosses::CheckDefeat.batched do
        add_hours(@user, FRIDAY, 3_600)
        raise "sync failed half way"
      end
    end
    assert @boss.reload.defeated?
    assert other.reload.defeated?
    assert_nil later.reload.defeated_at, "a boss whose dates were not credited is not checked"
  end
end
