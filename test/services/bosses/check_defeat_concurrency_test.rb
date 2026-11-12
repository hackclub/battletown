require "test_helper"
require_relative "../../support/bosses_helper"

# Real threads on real connections, so these tests commit (no wrapping transaction) and clean up after themselves.
class Bosses::CheckDefeatConcurrencyTest < ActiveSupport::TestCase
  include BossesHelper

  self.use_transactional_tests = false

  THREADS = 4

  setup do
    @users = Array.new(THREADS) { |index| User.create!(hca_uid: "ident!boss-race-#{index}-#{SecureRandom.hex(4)}", time_zone: "UTC", created_at: 1.year.ago) }
    @date = Time.current.utc.to_date
    @boss = make_boss(starts_on: @date - 1, hp_seconds: 1_000)
  end

  teardown do
    Boss.where(id: @boss.id).delete_all
    User.where(id: @users.map(&:id)).delete_all # the database cascades to hour_entries
  end

  def in_threads(count)
    gate = Queue.new
    threads = Array.new(count) do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          gate.pop
          yield index
        end
      end
    end
    count.times { gate << :go }
    threads.map(&:value)
  end

  test "several simultaneous ledger writes that cross the health set defeated_at exactly once" do
    in_threads(THREADS) do |index|
      Hours::Credit.call(user: User.find(@users[index].id), seconds: 600, source: "manual", note: "Race", local_date: @date, idempotency_key: "race-#{index}")
    end

    assert_equal 2_400, Bosses::Damage.for(@boss)
    assert @boss.reload.defeated?
    first = @boss.defeated_at

    # Re-running the check from many threads changes nothing.
    results = in_threads(THREADS) { Bosses::CheckDefeat.call(Boss.find(@boss.id)) }
    assert_equal [ false ] * THREADS, results
    assert_equal first, @boss.reload.defeated_at
  end

  test "of several simultaneous direct checks exactly one records the defeat" do
    HourEntry.insert_all!(@users.map.with_index { |user, index| { user_id: user.id, local_date: @boss.starts_on, seconds: 600, source: "manual", note: "t", idempotency_key: "direct-#{index}" } })

    results = in_threads(THREADS) { Bosses::CheckDefeat.call(Boss.find(@boss.id)) }

    assert_equal 1, results.count(true)
    assert_equal THREADS - 1, results.count(false)
    assert @boss.reload.defeated?
  end

  test "two entries that only together cross the health are both seen by the last check" do
    in_threads(2) do |index|
      HourEntry.create!(user: User.find(@users[index].id), local_date: @boss.starts_on, seconds: 600, source: "manual", note: "t", idempotency_key: "pair-#{index}")
    end

    assert @boss.reload.defeated?, "600 + 600 >= 1000"
  end
end
