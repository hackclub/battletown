require "test_helper"
require_relative "../../support/shop_helper"

class AdminUsers::CoinAdjustmentTest < ActiveSupport::TestCase
  include ShopTestHelper

  setup do
    @staff = users(:onboarded)
    @user = users(:new_user)
    @token = AdminUsers::Adjustment.new_token
  end

  def adjustment(**overrides)
    AdminUsers::CoinAdjustment.new(**{ staff: @staff, user: @user, direction: "add", coins: "25", reason: "Missing ship payout", token: @token }.merge(overrides))
  end

  test "adding coins writes one adjustment ledger entry and one audit event" do
    outcome = adjustment.apply!
    entry = outcome.record
    assert_equal [ "adjustment", 25, "Missing ship payout", "admin:#{@staff.id}", "admin_adjust:#{@token}" ],
                 [ entry.kind, entry.amount, entry.note, entry.created_by, entry.idempotency_key ]
    assert_equal 25, Coins::Balance.total(@user)
    event = AdminAuditEvent.sole
    assert_equal [ @staff.id, "coins_adjusted", "User", @user.id ], [ event.actor_id, event.action, event.subject_type, event.subject_id ]
    assert_equal({ "amount" => 25, "reason" => "Missing ship payout", "transaction_id" => entry.id, "balance_after" => 25 }, event.metadata)
  end

  test "taking coins off is a negative entry; the earlier entries are untouched" do
    seed = give_coins(@user, 100)
    outcome = adjustment(direction: "subtract", coins: "40").apply!
    assert_equal(-40, outcome.record.amount)
    assert_equal 100, seed.reload.amount
    assert_equal 60, Coins::Balance.total(@user)
    assert_equal(-40, AdminAuditEvent.sole.metadata["amount"])
    assert_equal 60, AdminAuditEvent.sole.metadata["balance_after"]
  end

  test "the balance can reach zero but never go below it" do
    give_coins(@user, 30)
    over = adjustment(direction: "subtract", coins: "31")
    assert_not over.valid?
    assert_match(/below zero \(it is 30 now\)/, over.errors.full_messages.to_sentence)
    assert_raises(AdminUsers::Adjustment::Invalid) { over.apply! }
    assert_equal 30, Coins::Balance.total(@user)
    assert_equal 0, AdminAuditEvent.count

    adjustment(direction: "subtract", coins: "30").apply!
    assert_equal 0, Coins::Balance.total(@user)
    assert_not adjustment(direction: "subtract", coins: "1", token: AdminUsers::Adjustment.new_token).valid?, "nothing left to take"
  end

  test "bounds: zero, negative, text, the maximum and one over" do
    max = AdminUsers::Config.current.max_adjust_coins
    [ "0", "-1", "abc", "", "2.5", (max + 1).to_s, "99999999999", " 5" ].each do |coins|
      form = adjustment(coins: coins)
      assert_not form.valid?, coins.inspect
      assert_includes form.errors.attribute_names, :coins
    end
    assert adjustment(coins: "1").valid?
    assert adjustment(coins: max.to_s).valid?
    assert_equal 500, max, "the default ceiling"
  end

  test "the same token twice changes the ledger once" do
    first = adjustment.apply!
    second = adjustment.apply!
    assert second.duplicate?
    assert_equal first.record.id, second.record.id
    assert_equal 25, Coins::Balance.total(@user)
    assert_equal 1, AdminAuditEvent.count
    assert adjustment(coins: "500", direction: "subtract").apply!.duplicate?, "a different amount under a used token is still just a repeat"
    assert_equal 25, Coins::Balance.total(@user)
  end

  test "staff cannot adjust their own coins" do
    own = AdminUsers::CoinAdjustment.new(staff: @staff, user: @staff, direction: "add", coins: "10", reason: "Giving myself some", token: @token)
    assert_not own.valid?
    assert_raises(AdminUsers::Adjustment::Invalid) { own.apply! }
    assert_equal 0, Coins::Balance.total(@staff)
    assert_equal 0, AdminAuditEvent.count
  end

  test "reason rules are the same as for hours" do
    [ "", "four", "x" * 201, "write to kid@example.test" ].each { |reason| assert_not adjustment(reason: reason).valid?, reason.inspect }
    assert_includes adjustment(reason: "").tap(&:valid?).errors.attribute_names, :reason
  end

  test "a refund-sized adjustment does not touch what the person can spend until they are verified" do
    adjustment.apply!
    assert_not @user.can_spend_coins?, "an adjustment adds to the balance, the spending gate is unchanged"
    assert_equal 25, Coins::Balance.total(@user)
  end

  test "the audit row failing rolls the ledger entry back" do
    original = AdminAudit.method(:record!)
    AdminAudit.define_singleton_method(:record!) { |**| raise ActiveRecord::StatementInvalid, "boom" }
    begin
      assert_raises(ActiveRecord::StatementInvalid) { adjustment.apply! }
    ensure
      AdminAudit.define_singleton_method(:record!, original)
    end
    assert_equal 0, CoinTransaction.where(user_id: @user.id).count
  end
end
