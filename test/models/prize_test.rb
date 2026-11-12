require "test_helper"

class PrizeTest < ActiveSupport::TestCase
  test "every item has an integer coin price and no other price" do
    assert_equal Prize.keys.uniq, Prize.keys
    Prize.all.each do |prize|
      assert_kind_of Integer, prize.coins, prize.key
      assert_operator prize.coins, :>=, 0, prize.key
    end
    assert_not_includes Prize.members, :price_usd
    assert_not_includes Prize.members, :hours, "hours is derived, not stored"
  end

  test "hours are derived from coins and the coins-per-hour setting" do
    per_hour = Game::Config.current.coins_per_hour
    assert_equal 10, per_hour
    assert_equal 2, Prize.find("sticker_pack").hours
    assert_equal "2 hours", Prize.find("sticker_pack").hours_text
    assert_equal "1 hour", Prize.find("custom_sticker").hours_text
    assert_equal "5 hours", Prize.find("tshirt").hours_text
    Prize.paid.each { |prize| assert_equal prize.coins / per_hour.to_f, prize.hours, prize.key }
  end

  test "hours show at most one decimal and follow the setting" do
    prize = Prize.new(key: "x", name: "X", description: "d", coins: 15, emoji: "x", image: nil, tier: "shop", free_signup: false)
    assert_equal 1.5, prize.hours
    assert_equal "1.5 hours", prize.hours_text
    assert_equal "0.1 hours", prize.with(coins: 1).hours_text
    assert_equal "0 hours", prize.with(coins: 0).hours_text
    assert_equal "3.3 hours", prize.with(coins: 33).hours_text

    doubled = Game::Config.current.with(coins_per_hour: 20)
    begin
      Game::Config.instance_variable_set(:@current, doubled)
      assert_equal "0.8 hours", prize.hours_text
      assert_equal "1 hour", prize.with(coins: 20).hours_text
    ensure
      Game::Config.reset!
    end
  end

  test "the free signup sticker is in the catalogue and the key list but not the paid list" do
    sticker = Prize.free_signup
    assert_equal "signup_sticker", sticker.key
    assert_predicate sticker, :free_signup?
    assert_equal 0, sticker.coins
    assert_includes Prize.keys, sticker.key
    assert_not_includes Prize.paid.map(&:key), sticker.key
    assert_equal 1, Prize.all.count(&:free_signup?)
    assert_empty Prize.paid.select { |prize| prize.coins.zero? }
  end

  test "the keys users already stored stay valid" do
    %w[sticker_pack custom_sticker tshirt enamel_pin keychain poster orpheus_plushie mechanical_keyboard headphones].each do |key|
      assert_includes Prize.keys, key
      user = users(:onboarded)
      user.prize_key = key
      assert_predicate user, :valid?, key
    end
    user = users(:onboarded)
    user.prize_key = "not_a_prize"
    assert_not user.valid?
  end

  test "the prize config holds no dollar figures" do
    text = Rails.root.join("config/prizes.yml").read
    assert_not_includes text, "$"
    assert_no_match(/usd/i, text)
    assert_no_match(/dollar|price_usd/i, text)
  end

  test "the catalogue says it is placeholder data" do
    assert_match(/PLACEHOLDER/, Rails.root.join("config/prizes.yml").read)
  end
end
