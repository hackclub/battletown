require "test_helper"
require_relative "../../support/merch_helper"

class MerchTrack::StaffTest < ActiveSupport::TestCase
  include MerchHelper

  setup do
    @original_env = ENV["ADMIN_HCA_UIDS"]
    @admin = users(:new_user)
    @admin.update_columns(hca_uid: "ident!merch-admin")
    ENV["ADMIN_HCA_UIDS"] = "ident!merch-admin"
    @boss = make_boss
    @user = claimant
    @claim = with_feature(:merch_track) { MerchTrack::Claim.call(user: @user, boss: @boss, now: AFTER_WEEK).claim }
  end

  teardown { @original_env.nil? ? ENV.delete("ADMIN_HCA_UIDS") : ENV["ADMIN_HCA_UIDS"] = @original_env }

  def fulfill(by: @admin) = with_feature(:merch_track) { MerchTrack::Fulfill.call(claim: @claim, by: by) }

  def cancel(by: @admin) = with_feature(:merch_track) { MerchTrack::Cancel.call(claim: @claim, by: by) }

  test "an admin fulfils a requested claim, and doing it again keeps the first time" do
    fulfill
    assert_predicate @claim.reload, :fulfilled?
    first = @claim.fulfilled_at
    assert_not_nil first
    travel(1.hour) { fulfill }
    assert_equal first, @claim.reload.fulfilled_at
  end

  test "an admin cancels a requested claim; there is no refund because no coins were involved" do
    assert_no_difference -> { CoinTransaction.count } do
      cancel
    end
    assert_predicate @claim.reload, :cancelled?
    assert_not_nil @claim.cancelled_at
    assert_predicate cancel, :cancelled?, "cancelling twice is idempotent"
  end

  test "a cancelled claim cannot be fulfilled and a fulfilled claim cannot be cancelled" do
    cancel
    assert_raises(MerchTrack::NotFulfillable) { fulfill }
    other_boss = make_boss(starts_on: WEEK_START + 7)
    goal_days(@user, 5, from: other_boss.starts_on)
    second = with_feature(:merch_track) { MerchTrack::Claim.call(user: @user, boss: other_boss, now: Time.utc(2026, 11, 27)).claim }
    with_feature(:merch_track) { MerchTrack::Fulfill.call(claim: second, by: @admin) }
    assert_raises(MerchTrack::NotCancellable) { with_feature(:merch_track) { MerchTrack::Cancel.call(claim: second, by: @admin) } }
  end

  test "only an admin can fulfil or cancel, the owner included" do
    [ @user, users(:onboarded), nil ].each do |person|
      assert_raises(MerchTrack::NotFulfillable) { fulfill(by: person) }
      assert_raises(MerchTrack::NotCancellable) { cancel(by: person) }
    end
    assert_predicate @claim.reload, :requested?
  end

  test "with the flag off staff cannot change a claim" do
    assert_raises(MerchTrack::Unavailable) { without_feature(:merch_track) { MerchTrack::Fulfill.call(claim: @claim, by: @admin) } }
    assert_raises(MerchTrack::Unavailable) { without_feature(:merch_track) { MerchTrack::Cancel.call(claim: @claim, by: @admin) } }
    assert_predicate @claim.reload, :requested?
  end
end
