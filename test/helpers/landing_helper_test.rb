require "test_helper"

class LandingHelperTest < ActionView::TestCase
  test "the call to action says join the fight with no count" do
    assert_equal "Join the fight", join_cta_label(nil)
    assert_equal "Join the fight", join_cta_label
  end

  test "it quotes the count in a pill when given one" do
    assert_equal 'Join <span class="cta__count">51</span> other fighters', join_cta_label(51)
    assert_equal 'Join <span class="cta__count">1,234</span> other fighters', join_cta_label(1234)
  end

  test "a fighter count only shows once it is over fifty" do
    assert_equal 51, LandingHelper::FIGHTER_COUNT_THRESHOLD
  end

  test "landing boss is a full decorative bar when there is no boss" do
    assert_equal({ live: false, percent: 100, text: "Full health. The next boss is on its way", label: "Next boss on its way" }, landing_boss)
  end

  test "the hero painting comes in four widths" do
    assert_equal %w[1280w 1920w 2880w 3840w], hero_art_srcset.values
    assert(hero_art_srcset.keys.all? { |path| Rails.root.join("app/assets/images", path).exist? })
  end

  test "a prize's podium art is its own image, then a matching photo, else nothing" do
    prize = Prize.find("mechanical_keyboard")
    assert_equal "landing/prizes/keychron-k2.webp", prize_art(prize)
    assert_equal "x.webp", prize_art(prize.with(image: "x.webp"))
    assert_nil prize_art(Prize.find("sticker_pack"))
  end
end
