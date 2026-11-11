require "test_helper"

class AccountDeletionTest < ActiveSupport::TestCase
  test "deletes the user row and only that user" do
    assert_difference "User.count", -1 do
      assert AccountDeletion.call(users(:onboarded))
    end
    assert_not User.exists?(users(:onboarded).id)
    assert User.exists?(users(:new_user).id)
  end

  test "the same Hack Club identity can sign up again as a fresh user" do
    uid = users(:onboarded).hca_uid
    AccountDeletion.call(users(:onboarded))

    user = User.from_hca_claims!({ "sub" => uid, "email" => "back@example.com" })

    assert user.persisted?
    assert_not user.onboarded?
    assert_nil user.prize_key
  end

  test "fails loudly, and changes nothing, if the row is already gone" do
    user = users(:onboarded)
    User.where(id: user.id).delete_all

    assert_raises(AccountDeletion::Failed) { AccountDeletion.call(user) }
  end

  test "logs the event without any personal data" do
    user = users(:onboarded)
    io = StringIO.new
    old = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    begin
      AccountDeletion.call(user)
    ensure
      Rails.logger = old
    end

    assert_includes io.string, "Account deleted"
    [ user.email, user.display_name, user.hca_uid, user.id.to_s ].each { |pii| assert_not_includes io.string, pii }
  end
end
