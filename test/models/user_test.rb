require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "fixtures are valid" do
    assert users(:new_user).valid?
    assert users(:onboarded).valid?
  end

  test "hca_uid is required and unique" do
    assert_not User.new.valid?
    assert_not User.new(hca_uid: users(:new_user).hca_uid).valid?
  end

  test "rejects values outside the allowlists" do
    user = users(:new_user)
    {
      prize_key: "free_laptop",
      project_kind: "malware",
      coding_time: "25:99",
      time_zone: "Mars/Olympus",
      referral_source: "Has Spaces!",
      project_idea: "x" * 501
    }.each do |attribute, value|
      user[attribute] = value
      assert_not user.valid?, "#{attribute} should be rejected"
      user.reload
    end
  end

  test "coding days round-trip through the bitmask" do
    user = users(:new_user)
    user.coding_day_names = %w[monday wednesday sunday bogus]
    assert_equal 1 + 4 + 64, user.coding_days
    assert_equal %w[monday wednesday sunday], user.coding_day_names
  end

  test "onboarded? depends on onboarded_at" do
    assert users(:onboarded).onboarded?
    assert_not users(:new_user).onboarded?
  end

  test "from_hca_claims! creates a user, ignoring birthdate and unknown status" do
    claims = { "sub" => "ident!fresh", "name" => "Fresh", "email" => "f@example.com", "slack_id" => "U123",
               "verification_status" => "bogus", "ysws_eligible" => true, "birthdate" => "2010-01-01" }
    user = User.from_hca_claims!(claims, referral_source: "haven")

    assert user.persisted?
    assert_equal "haven", user.referral_source
    assert user.verification_needs_submission?
    assert user.ysws_eligible
  end

  test "from_hca_claims! updates claims but keeps the original referral" do
    user = User.from_hca_claims!({ "sub" => users(:onboarded).hca_uid, "verification_status" => "verified" }, referral_source: "terra")

    assert_equal users(:onboarded).id, user.id
    assert_nil user.referral_source
    assert user.verification_verified?
  end

  test "from_hca_claims! survives losing the race to create the same user" do
    attempts = 0
    # Simulate a concurrent first login: another request inserts the row between our lookup and INSERT.
    inserter = lambda do |_record|
      attempts += 1
      if attempts == 1
        ActiveRecord::Base.connection.execute("INSERT INTO users (hca_uid, created_at, updated_at) VALUES ('ident!race', now(), now())")
      end
    end
    User.set_callback(:create, :before, inserter)
    begin
      assert_difference "User.count", 1 do
        user = User.from_hca_claims!({ "sub" => "ident!race", "name" => "Racer" })
        assert_equal "Racer", user.reload.display_name
      end
    ensure
      User.skip_callback(:create, :before, inserter)
    end
  end

  test "overlong display names are truncated instead of blocking sign-in" do
    user = User.from_hca_claims!({ "sub" => "ident!long", "name" => "x" * 300 })
    assert_equal 100, user.display_name.length
  end
end
