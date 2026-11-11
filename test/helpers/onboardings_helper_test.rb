require "test_helper"

class OnboardingsHelperTest < ActionView::TestCase
  test "referral_name returns display names for generic keys and programs" do
    assert_equal "Hack Club Slack or community", referral_name("hack_club")
    assert_equal "A friend or family member", referral_name("friend")
    assert_equal "Google or another search engine", referral_name("search")
    assert_equal "X / Twitter", referral_name("twitter")
    assert_equal "Something else", referral_name("other")
    assert_equal "Haven", referral_name("haven")
    assert_nil referral_name("evilcorp")
    assert_nil referral_name(nil)
  end

  test "referral_summary words program links and survey answers differently" do
    assert_equal "You came from Haven.", referral_summary("haven")
    assert_equal "You told us: YouTube.", referral_summary("youtube")
    assert_equal "Thanks for joining through a friend.", referral_summary("legacy")
  end
end
