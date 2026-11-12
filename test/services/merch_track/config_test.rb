require "test_helper"

class MerchTrack::ConfigTest < ActiveSupport::TestCase
  GAME_YML = Rails.root.join("config/game.yml")

  def raw = Rails.application.config_for(:game).fetch(:merch_track).deep_dup

  def build(**changes) = MerchTrack::Config.from_hash(merch_track: raw.merge(changes))

  test "the shipped defaults" do
    config = MerchTrack::Config.current
    assert_equal 5, config.days_required
    assert_equal true, config.claim_requires_ship
    assert_equal "none", config.after_last_week
    assert_equal 4, config.items.size
    assert_equal %w[week_1_sticker week_2_item week_3_item week_4_item], config.items.map(&:key)
    assert(config.items.all? { |item| item.name.present? && item.description.present? && item.emoji.present? })
  end

  test "the item for a boss week follows the order, and after the last week it is none or the last item" do
    config = MerchTrack::Config.current
    assert_equal "week_1_sticker", config.item_for(0).key
    assert_equal "week_4_item", config.item_for(3).key
    assert_nil config.item_for(4)
    assert_nil config.item_for(-1)
    assert_equal "week_4_item", build(after_last_week: "repeat_last").item_for(9).key
  end

  test "bad values are refused with a message that names the key" do
    [ { days_required: 0 }, { days_required: 8 }, { days_required: "5" }, { claim_requires_ship: "yes" }, { after_last_week: "forever" },
      { week_items: [] }, { week_items: [ { key: "Bad Key", name: "x", description: "" } ] },
      { week_items: [ { key: "a", name: "", description: "" } ] },
      { week_items: [ { key: "a", name: "x", description: "y" * 161 } ] },
      { week_items: [ { key: "a", name: "x", description: "" }, { key: "a", name: "y", description: "" } ] } ].each do |changes|
      error = assert_raises(ArgumentError, changes.inspect) { build(**changes) }
      assert_match(/merch_track/, error.message)
    end
  end

  test "no dollar figures or prices appear in the merch track config" do
    text = GAME_YML.read[/^  merch_track:.*?(?=^  \w|\z)/m]
    assert_not_nil text, "the merch_track section is missing from config/game.yml"
    assert_no_match(/[$£€]/, text)
    assert_no_match(/\b(usd|dollars?|cents?|price|prices|cost|costs|budget|\bper hour)\b/i, text)
    assert_no_match(/\d+\.\d{2}\b/, text)
    MerchTrack::Config.current.items.each do |item|
      assert_no_match(/[$£€]|\d[\d.,]*\s*(usd|dollars?|cents?)/i, "#{item.name} #{item.description}", "#{item.key} reads like it carries a figure")
    end
  end
end
