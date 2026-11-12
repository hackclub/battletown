require "test_helper"
require_relative "../../support/merch_helper"

class MerchTrack::ClaimTest < ActiveSupport::TestCase
  include MerchHelper

  setup do
    @boss = make_boss
    @user = claimant
  end

  def claim(user: @user, boss: @boss, now: AFTER_WEEK, **changes)
    with_feature(:merch_track) { MerchTrack::Claim.call(user: user, boss: boss, now: now, config: config(**changes)) }
  end

  test "an earned, verified person with an approved ship claims the week's item" do
    result = claim
    assert result.created
    claim = result.claim
    assert_equal @user, claim.user
    assert_equal @boss, claim.boss
    assert_equal "week_1_sticker", claim.item_key
    assert_equal "Week 1 sticker", claim.item_name
    assert_predicate claim, :requested?
    assert_equal AFTER_WEEK, claim.claimed_at
  end

  test "no coins move and no order is made" do
    assert_no_difference -> { CoinTransaction.count } do
      assert_no_difference -> { Order.count } do
        claim
      end
    end
  end

  test "four goal days have not earned it" do
    user = claimant(goal_count: 4)
    assert_raises(MerchTrack::NotEarned) { claim(user: user) }
    assert_equal 0, MerchClaim.where(user_id: user.id).count
  end

  test "an unverified person is locked out with the friendly message, and nothing is created" do
    @user.update_columns(verification_status: "pending")
    error = assert_raises(MerchTrack::NotVerified) { claim }
    assert_match(/verify your identity with Hack Club/, error.message)
    assert_equal 0, MerchClaim.count
  end

  test "an ineligible or unsubmitted verification is locked too" do
    %w[needs_submission ineligible].each do |status|
      @user.update_columns(verification_status: status)
      assert_raises(MerchTrack::NotVerified, status) { claim }
    end
  end

  test "the ship requirement: refused without an approved ship, allowed with one, skipped when switched off" do
    user = verified!(build_user)
    goal_days(user, 5)
    assert_raises(MerchTrack::NeedsShip) { claim(user: user) }
    assert_equal 0, MerchClaim.count
    assert claim(user: user, claim_requires_ship: false).created
  end

  test "a submitted or rejected ship is not an approved ship" do
    user = verified!(build_user)
    goal_days(user, 5)
    project = Project.create!(user: user, name: "Pending", kind: "game")
    Ship.create!(user: user, project: project, status: "submitted", description: "d", repo_url: "https://github.com/octo/pending", coded_seconds: 3600,
                 window_start_date: Date.new(2026, 11, 9), window_end_date: Date.new(2026, 11, 9), daily_seconds: { "2026-11-09" => 3600 },
                 submitted_at: Time.utc(2026, 11, 10))
    assert_raises(MerchTrack::NeedsShip) { claim(user: user) }
  end

  test "a ship approved after the week still unlocks an earlier week" do
    user = verified!(build_user)
    goal_days(user, 5)
    approved_ship!(user)
    assert claim(user: user, now: Time.utc(2026, 12, 20)).created
  end

  test "claiming twice is idempotent: one row, the same claim, created only the first time" do
    first = claim
    second = claim
    assert first.created
    assert_not second.created
    assert_equal first.claim.id, second.claim.id
    assert_equal 1, MerchClaim.count
  end

  test "claiming again after staff fulfilled or cancelled returns the same claim and changes nothing" do
    first = claim.claim
    first.update!(status: "cancelled", cancelled_at: Time.current)
    again = claim
    assert_not again.created
    assert_predicate again.claim, :cancelled?
    assert_equal 1, MerchClaim.count
  end

  test "a different week needs its own goal days: wrong week and future week are refused" do
    second = make_boss(starts_on: WEEK_START + 7)
    assert_raises(MerchTrack::NotEarned) { claim(boss: second) }
    assert_raises(MerchTrack::NotEarned) { claim(boss: second, now: Time.utc(2026, 11, 10)) }
    assert_equal 0, MerchClaim.count
  end

  test "a week with no item on the track cannot be claimed" do
    (1..4).each { |n| make_boss(starts_on: WEEK_START + 7 * n) }
    fifth = Boss.chronological.last
    goal_days(@user, 5, from: fifth.starts_on)
    assert_raises(MerchTrack::NoReward) { claim(boss: fifth, now: Time.utc(2026, 12, 20)) }
    assert claim(boss: fifth, now: Time.utc(2026, 12, 20), after_last_week: "repeat_last").created
  end

  test "frozen days do not count towards a claim" do
    user = verified!(build_user)
    goal_days(user, 4)
    goal_day(user, WEEK_START + 4, frozen: true)
    approved_ship!(user)
    assert_raises(MerchTrack::NotEarned) { claim(user: user) }
  end

  test "with the flag off nothing is created" do
    assert_raises(MerchTrack::Unavailable) do
      without_feature(:merch_track) { MerchTrack::Claim.call(user: @user, boss: @boss, now: AFTER_WEEK, config: config) }
    end
    assert_equal 0, MerchClaim.count
  end

  test "claims are unique per person and week in the database too" do
    claim
    assert_raises(ActiveRecord::RecordNotUnique) do
      MerchClaim.insert!({ user_id: @user.id, boss_id: @boss.id, item_key: "x", item_name: "X", status: "requested", claimed_at: Time.current })
    end
  end

  test "the database refuses a status that does not fit its timestamps" do
    claimed = claim.claim
    assert_raises(ActiveRecord::StatementInvalid) { claimed.update_columns(status: "fulfilled") }
    assert_raises(ActiveRecord::StatementInvalid) { claimed.update_columns(status: "lost") }
  end
end
