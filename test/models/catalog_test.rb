require "test_helper"

class CatalogTest < ActiveSupport::TestCase
  test "prizes load from config" do
    assert_operator Prize.all.size, :>=, 8
    assert_equal "T-shirt", Prize.find("tshirt").name.sub("Battletown ", "")
    assert_nil Prize.find("nope")
    assert_equal Prize.keys.uniq, Prize.keys
  end

  test "referrals load from config" do
    assert_equal %w[haven stardance terra], Referral.all.map(&:slug)
    assert_equal "Haven", Referral.find("haven").name
    assert_nil Referral.find("evil")
  end

  test "referral sources are generic answers, then programs, then something else" do
    keys = ReferralSource.keys
    assert_equal keys.uniq, keys
    assert_equal %w[hack_club friend teacher search youtube tiktok instagram reddit discord twitter github], ReferralSource.generic.map(&:key)
    assert_equal %w[haven stardance terra], ReferralSource.programs.map(&:key)
    assert_equal "other", keys.last
    assert_empty ReferralSource.generic.map(&:key) & Referral.all.map(&:slug), "generic keys must not be attribution slugs"
    assert_empty ReferralSource.keys.reject { |key| key.match?(Referral::FORMAT) }
    assert_nil ReferralSource.find("evil")
    assert_nil ReferralSource.find(nil)
  end
end
