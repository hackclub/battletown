require "test_helper"
require_relative "../support/merch_helper"

class MerchClaimTest < ActiveSupport::TestCase
  include MerchHelper

  setup do
    @boss = make_boss
    @user = build_user
  end

  def build_claim(**attrs)
    MerchClaim.new({ user: @user, boss: @boss, item_key: "week_1_sticker", item_name: "Week 1 sticker", claimed_at: Time.current }.merge(attrs))
  end

  test "a claim needs an item, a known status and a claim time" do
    assert build_claim.valid?
    assert_not build_claim(item_key: "").valid?
    assert_not build_claim(item_name: "").valid?
    assert_not build_claim(status: "lost").valid?
    assert_not build_claim(claimed_at: nil).valid?
  end

  test "one claim per person per week" do
    build_claim.save!
    assert_not build_claim.valid?
    assert build_claim(boss: make_boss(starts_on: WEEK_START + 7)).valid?
  end

  test "a claim holds no address, no coins and no free text" do
    assert_empty MerchClaim.column_names & %w[address street city phone coins amount note email name]
  end

  test "the foreign keys cascade: deleting the person or the boss removes the claim" do
    build_claim.save!
    @user.delete
    assert_equal 0, MerchClaim.count
    other = build_user
    MerchClaim.create!(user: other, boss: @boss, item_key: "a", item_name: "A", claimed_at: Time.current)
    @boss.delete
    assert_equal 0, MerchClaim.count
  end

  test "the data-deletion dry run counts and removes merch claims" do
    build_claim.save!
    subject = Privacy::TokenVerifier::Subject.new(emails: [], slack_id: nil, identity_id: @user.hca_uid)
    result = Privacy::Deleter.new(subject).call(dry_run: true)
    assert_equal 1, result.deleted["merch_claims"]
    assert_equal 1, MerchClaim.count, "a dry run rolls back"
    Privacy::Deleter.new(subject).call(dry_run: false)
    assert_equal 0, MerchClaim.count
  end
end
