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
end
