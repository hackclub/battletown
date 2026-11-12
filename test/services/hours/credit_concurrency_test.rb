require "test_helper"

# Real threads on real connections, so these tests commit (no wrapping transaction) and clean up after themselves.
class Hours::CreditConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  THREADS = 4

  setup do
    @user = User.create!(hca_uid: "ident!concurrency-#{SecureRandom.hex(4)}", time_zone: "UTC")
    @date = Time.current.utc.to_date
  end

  teardown { User.where(id: @user.id).delete_all } # the database cascades to hour_entries

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

  test "simultaneous credits for one user are serialised and the daily cap holds" do
    results = in_threads(THREADS) do |index|
      Hours::Credit.call(user: User.find(@user.id), seconds: 20_000, source: "manual", note: "Race", local_date: @date, idempotency_key: "race-#{index}")
    end

    total = HourEntry.where(user_id: @user.id, local_date: @date).sum(:seconds)
    assert_equal 43_200, total, "the day is filled exactly to the cap, never past it"
    assert_equal 43_200, results.sum(&:credited_seconds)
    assert_equal [ :capped, :clamped, :created, :created ], results.map(&:status).sort
  end

  test "simultaneous credits with one key write one row" do
    results = in_threads(THREADS) do
      Hours::Credit.call(user: User.find(@user.id), seconds: 600, source: "manual", note: "Race", local_date: @date, idempotency_key: "same-key")
    end

    assert_equal 1, HourEntry.where(user_id: @user.id).count
    assert_equal 1, results.count(&:created?)
    assert_equal THREADS - 1, results.count(&:duplicate?)
    assert_equal 1, results.map { |result| result.entry.id }.uniq.size
  end

  test "simultaneous syncs of the same report credit it once" do
    rows = [ Hackatime::DaySeconds.new(date: @date, seconds: 3_600, project: "game") ]
    in_threads(THREADS) { Hours::Sync.call(rows, user: User.find(@user.id)) }

    assert_equal 3_600, HourEntry.where(user_id: @user.id).sum(:seconds)
    assert_equal 1, HourEntry.where(user_id: @user.id).count
  end
end
