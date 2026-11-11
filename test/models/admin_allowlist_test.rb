require "test_helper"

class AdminAllowlistTest < ActiveSupport::TestCase
  def with_env(value)
    original = ENV["ADMIN_HCA_UIDS"]
    value.nil? ? ENV.delete("ADMIN_HCA_UIDS") : ENV["ADMIN_HCA_UIDS"] = value
    yield
  ensure
    original.nil? ? ENV.delete("ADMIN_HCA_UIDS") : ENV["ADMIN_HCA_UIDS"] = original
  end

  test "absent, empty and blank-only env means nobody is an admin" do
    [ nil, "", "   ", " , ,, " ].each do |value|
      with_env(value) do
        assert_empty AdminAllowlist.uids, value.inspect
        assert_not AdminAllowlist.include?("ident!onboarded"), value.inspect
        assert_not AdminAllowlist.include?(""), value.inspect
        assert_not AdminAllowlist.include?(nil), value.inspect
      end
    end
  end

  test "trims whitespace, ignores blanks and drops duplicates" do
    with_env(" a1 ,, b2 ,a1,\tc3\n") do
      assert_equal %w[a1 b2 c3], AdminAllowlist.uids
    end
  end

  test "matches exactly: no prefix, suffix or substring match" do
    with_env("ident!onboarded") do
      assert AdminAllowlist.include?("ident!onboarded")
      assert_not AdminAllowlist.include?("ident!onboarded2")
      assert_not AdminAllowlist.include?("xident!onboarded")
      assert_not AdminAllowlist.include?("ident!")
      assert_not AdminAllowlist.include?("onboarded")
    end
  end

  test "matches case-sensitively" do
    with_env("ident!Onboarded") do
      assert AdminAllowlist.include?("ident!Onboarded")
      assert_not AdminAllowlist.include?("ident!onboarded")
    end
  end

  test "is read from the environment on every call" do
    with_env("one") { assert AdminAllowlist.include?("one") }
    with_env("two") { assert_not AdminAllowlist.include?("one") }
  end

  test "User#admin? follows the allowlist by hca_uid" do
    user = users(:onboarded)
    with_env(nil) { assert_not user.admin? }
    with_env("other,#{user.hca_uid}") { assert user.admin? }
    with_env(users(:new_user).hca_uid) { assert_not user.admin? }
  end
end
