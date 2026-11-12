require "test_helper"

# Real threads on real connections, so these tests commit (no wrapping transaction) and clean up after themselves.
class AdminUsers::AdjustmentConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  THREADS = 4

  setup do
    @staff = User.create!(hca_uid: "ident!adjust-staff-#{SecureRandom.hex(4)}", time_zone: "UTC")
    @user = User.create!(hca_uid: "ident!adjust-user-#{SecureRandom.hex(4)}", time_zone: "UTC")
    @date = Time.current.utc.to_date
  end

  # The audit trail outlives the people it is about (that is the point), so these committed rows are removed by hand.
  teardown do
    AdminAuditEvent.where(subject_type: "User", subject_id: [ @staff.id, @user.id ]).delete_all
    User.where(id: [ @staff.id, @user.id ]).delete_all
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

  test "the same hours form submitted from several tabs at once writes one entry and one audit event" do
    token = AdminUsers::Adjustment.new_token
    outcomes = in_threads(THREADS) do
      AdminUsers::HoursAdjustment.new(staff: User.find(@staff.id), user: User.find(@user.id), direction: "add", date: @date.iso8601, minutes: "30",
                                      reason: "Double click", token: token).apply!
    end

    assert_equal 1, outcomes.count { |outcome| !outcome.duplicate? }
    assert_equal 1800, HourEntry.where(user_id: @user.id, source: "adjustment").sum(:seconds)
    assert_equal 1, AdminAuditEvent.where(subject_type: "User", subject_id: @user.id, action: "hours_adjusted").count
  end

  test "the same coin form submitted at once writes one entry and one audit event" do
    token = AdminUsers::Adjustment.new_token
    outcomes = in_threads(THREADS) do
      AdminUsers::CoinAdjustment.new(staff: User.find(@staff.id), user: User.find(@user.id), direction: "add", coins: "40", reason: "Double click", token: token).apply!
    end

    assert_equal 1, outcomes.count { |outcome| !outcome.duplicate? }
    assert_equal 40, Coins::Balance.total(@user)
    assert_equal 1, AdminAuditEvent.where(subject_id: @user.id, action: "coins_adjusted").count
  end

  test "two staff members taking coins at once cannot take the balance below zero" do
    Coins::Ledger.credit(user: @user, amount: 100, kind: "adjustment", idempotency_key: "seed")
    results = in_threads(THREADS) do
      AdminUsers::CoinAdjustment.new(staff: User.find(@staff.id), user: User.find(@user.id), direction: "subtract", coins: "60", reason: "Race for coins",
                                     token: AdminUsers::Adjustment.new_token).apply!
      :applied
    rescue AdminUsers::Adjustment::Invalid
      :refused
    end

    assert_equal 1, results.count(:applied)
    assert_equal THREADS - 1, results.count(:refused)
    assert_equal 40, Coins::Balance.total(@user)
    assert_equal 1, AdminAuditEvent.where(subject_id: @user.id, action: "coins_adjusted").count
  end

  test "two staff members taking time off at once cannot take a day below zero" do
    HourEntry.create!(user: @user, local_date: @date, seconds: 3600, source: "manual", note: "seed", idempotency_key: "seed")
    results = in_threads(THREADS) do
      AdminUsers::HoursAdjustment.new(staff: User.find(@staff.id), user: User.find(@user.id), direction: "subtract", date: @date.iso8601, minutes: "40",
                                      reason: "Race for time", token: AdminUsers::Adjustment.new_token).apply!
      :applied
    rescue AdminUsers::Adjustment::Invalid
      :refused
    end

    assert_equal 1, results.count(:applied)
    assert_equal 1200, HourEntry.where(user_id: @user.id, local_date: @date).sum(:seconds)
  end
end
