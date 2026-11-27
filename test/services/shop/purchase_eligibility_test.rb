require "test_helper"
require_relative "../../support/shop_helper"

# Shop::Purchase and Shop::Spendable with the `eligibility_gate` flag in both states: which typed error, and that
# nothing is written. The flag-off behaviour is also what the unchanged Shop::PurchaseTest checks.
class Shop::PurchaseEligibilityTest < ActiveSupport::TestCase
  include ShopTestHelper

  setup do
    @user = build_user
    give_coins(@user, 500)
  end

  def state!(status:, eligible:, checked_at: Time.current)
    @user.update_columns(verification_status: status, ysws_eligible: eligible, verification_checked_at: checked_at)
  end

  def assert_refused(error)
    assert_no_difference [ "Order.count", "CoinTransaction.count" ] do
      raised = assert_raises(error) { buy(@user) }
      yield raised if block_given?
    end
    assert_equal 500, Coins::Balance.total(@user)
    assert_equal 0, Shop::Spendable.balance(@user)
    assert Shop::Spendable.locked?(@user)
  end

  test "flag on, unverified: NotVerified" do
    with_feature(:eligibility_gate) do
      state!(status: "needs_submission", eligible: true)
      assert_refused(Shop::NotVerified)
    end
  end

  test "flag on, verified but not eligible: NotEligible, with kind words and no reason" do
    with_feature(:eligibility_gate) do
      state!(status: "verified", eligible: false)
      assert_refused(Shop::NotEligible) do |error|
        assert_equal "Prizes are only available to people who qualify for Hack Club YSWS programs. Your account does not qualify yet. Questions? Ask in Slack.", error.message
        assert_kind_of Shop::Error, error
      end
    end
  end

  test "flag on, verified and eligible but the check is too old: NeedsRecheck" do
    with_feature(:eligibility_gate) do
      state!(status: "verified", eligible: true, checked_at: 31.days.ago)
      assert_refused(Shop::NeedsRecheck) { |error| assert_equal "Sign in again to refresh your verification.", error.message }
    end
  end

  test "flag on, verified, eligible and fresh: the purchase goes through" do
    with_feature(:eligibility_gate) do
      state!(status: "verified", eligible: true, checked_at: 29.days.ago)
      assert_equal 500, Shop::Spendable.balance(@user)
      assert_difference "Order.count", 1 do
        buy(@user)
      end
      assert_equal 450, Coins::Balance.total(@user)
    end
  end

  test "flag off: only verification matters, whatever the eligibility or the age of the check" do
    without_feature(:eligibility_gate) do
      state!(status: "verified", eligible: false, checked_at: 1000.days.ago)
      assert_difference "Order.count", 1 do
        buy(@user)
      end
      state!(status: "needs_submission", eligible: true)
      assert_raises(Shop::NotVerified) { buy(@user) }
    end
  end

  test "a replayed purchase made before the person became ineligible still returns the same order" do
    with_feature(:eligibility_gate) do
      state!(status: "verified", eligible: true)
      order = buy(@user, "tshirt", key: "same")
      state!(status: "verified", eligible: false)
      assert_raises(Shop::NotEligible) { buy(@user, "tshirt", key: "other") }
      assert_equal order, buy(@user, "tshirt", key: "same")
    end
  end

  test "the free sticker is not gated" do
    with_feature(:eligibility_gate) do
      state!(status: "verified", eligible: false)
      assert_difference "Order.count", 1 do
        Shop::ClaimSticker.call(user: @user)
      end
    end
  end

  test "check! raises nothing for a ready user" do
    with_feature(:eligibility_gate) do
      state!(status: "verified", eligible: true)
      assert_nil Shop::Spendable.check!(@user)
    end
  end
end
