require "test_helper"

# User#can_spend_coins? and #spend_state: the one decision every note, banner, page and the shop purchase read.
class UserSpendStateTest < ActiveSupport::TestCase
  setup { @user = users(:onboarded) }

  def set(status:, eligible:, checked_at: Time.current)
    @user.update_columns(verification_status: status, ysws_eligible: eligible, verification_checked_at: checked_at)
    @user.reload
  end

  # [status, ysws_eligible, state with the flag off, state with the flag on]. "Unverified" is every status but verified.
  MATRIX = [
    [ "needs_submission", false, :unverified, :unverified ],
    [ "needs_submission", true, :unverified, :unverified ],
    [ "pending", true, :unverified, :unverified ],
    [ "ineligible", true, :unverified, :unverified ],
    [ "verified", false, :ready, :not_eligible ],
    [ "verified", true, :ready, :ready ]
  ].freeze

  MATRIX.each do |status, eligible, off_state, on_state|
    test "#{status} with ysws_eligible #{eligible}: #{off_state} with the flag off, #{on_state} with it on" do
      set(status: status, eligible: eligible)
      without_feature(:eligibility_gate) do
        assert_equal off_state, @user.spend_state
        assert_equal(status == "verified", @user.can_spend_coins?, "flag off is exactly 'verified'")
      end
      with_feature(:eligibility_gate) do
        assert_equal on_state, @user.spend_state
        assert_equal on_state == :ready, @user.can_spend_coins?
      end
    end
  end

  test "flag off: eligibility and the age of the verification are ignored, as before the gate" do
    set(status: "verified", eligible: false, checked_at: 400.days.ago)
    assert_predicate @user, :can_spend_coins?
    assert_equal :ready, @user.spend_state
  end

  test "flag on: a verification older than the maximum age needs a re-check, even when eligible" do
    with_feature(:eligibility_gate) do
      max = Eligibility::Config.current.verification_max_age_days
      set(status: "verified", eligible: true, checked_at: (max.days - 1.hour).ago)
      assert_equal :ready, @user.spend_state
      set(status: "verified", eligible: true, checked_at: (max.days + 1.hour).ago)
      assert_equal :stale, @user.spend_state
      assert_not @user.can_spend_coins?
      assert_predicate @user, :verification_stale?
    end
  end

  test "flag on: a stale copy asks for a re-check before saying not eligible (the old answer may be out of date)" do
    with_feature(:eligibility_gate) do
      set(status: "verified", eligible: false, checked_at: 90.days.ago)
      assert_equal :stale, @user.spend_state
    end
  end

  test "flag on: only verified people are ever stale; an unverified person stays unverified" do
    with_feature(:eligibility_gate) do
      set(status: "pending", eligible: true, checked_at: 90.days.ago)
      assert_equal :unverified, @user.spend_state
    end
  end

  test "the maximum age is the configured number of days" do
    original = Eligibility::Config.current
    begin
      Eligibility::Config.instance_variable_set(:@current, Eligibility::Config.new(verification_max_age_days: 2, help_line: "Ask."))
      with_feature(:eligibility_gate) do
        set(status: "verified", eligible: true, checked_at: 3.days.ago)
        assert_equal :stale, @user.spend_state
        set(status: "verified", eligible: true, checked_at: 1.day.ago)
        assert_equal :ready, @user.spend_state
      end
    ensure
      Eligibility::Config.instance_variable_set(:@current, original)
    end
  end

  test "a missing check time counts as old" do
    with_feature(:eligibility_gate) do
      set(status: "verified", eligible: true)
      @user.verification_checked_at = nil
      assert_equal :stale, @user.spend_state
    end
  end

  test "a new row without a check time starts fresh (database default), so other code that creates users is not locked out" do
    user = User.create!(hca_uid: "ident!fresh", verification_status: "verified", ysws_eligible: true)
    assert_in_delta Time.current, user.reload.verification_checked_at, 60
    with_feature(:eligibility_gate) { assert_predicate user, :can_spend_coins? }
  end

  test "applying Hack Club claims stores the verification, the eligibility and when they were checked" do
    travel_to Time.utc(2026, 11, 12, 10) do
      user = User.from_hca_claims!({ "sub" => "ident!claims", "verification_status" => "verified", "ysws_eligible" => true })
      assert_equal Time.utc(2026, 11, 12, 10), user.reload.verification_checked_at
      assert_predicate user, :ysws_eligible?
    end
    travel_to Time.utc(2026, 12, 20, 10) do
      user = User.from_hca_claims!({ "sub" => "ident!claims", "verification_status" => "verified", "ysws_eligible" => false })
      assert_equal Time.utc(2026, 12, 20, 10), user.reload.verification_checked_at
      assert_not user.ysws_eligible?
    end
  end
end

class EligibilityConfigTest < ActiveSupport::TestCase
  test "defaults in config/game.yml" do
    config = Eligibility::Config.current
    assert_equal 30, config.verification_max_age_days
    assert_equal 30.days, config.max_age
    assert_equal "Questions? Ask in Slack.", config.help_line
  end

  test "rejects a zero or negative age and a missing or overlong help line" do
    assert_raises(ArgumentError) { Eligibility::Config.from_hash(verification_max_age_days: 0, help_line: "x") }
    assert_raises(ArgumentError) { Eligibility::Config.from_hash(verification_max_age_days: -3, help_line: "x") }
    assert_raises(ArgumentError) { Eligibility::Config.from_hash(verification_max_age_days: 30, help_line: " ") }
    assert_raises(ArgumentError) { Eligibility::Config.from_hash(verification_max_age_days: 30, help_line: "x" * 201) }
    assert_raises(ArgumentError) { Eligibility::Config.from_hash(verification_max_age_days: "soon", help_line: "x") }
  end
end
