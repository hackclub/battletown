require "test_helper"
require_relative "../support/ship_images_helper"

# Prize is a facade over the shop_items table with the API the app has always used (test/models/prize_test.rb keeps the
# original assertions); these cover what is new: archived items, ordering, caching and the fallbacks.
class PrizeCatalogueTest < ActiveSupport::TestCase
  include ShipImagesHelper

  def archive(key) = ShopItem.find_by!(key: key).update!(active: false)

  test "the same public API as before: all, paid, free_signup, keys, find, hours" do
    %i[all paid free_signup keys find active reload!].each { |name| assert_respond_to Prize, name }
    assert_equal %i[key name description coins emoji image tier free_signup active position], Prize.members
    prize = Prize.find("tshirt")
    assert_equal [ "Battletown T-shirt", 50, "shop", false, true ], [ prize.name, prize.coins, prize.tier, prize.free_signup?, prize.active? ]
    assert_equal 5, prize.hours
    assert_equal "5 hours", prize.hours_text
    assert_nil prize.image
    assert_equal Prize.find("tshirt"), Prize.find(:tshirt)
    assert_nil Prize.find(nil)
    assert_nil Prize.find("nope")
  end

  test "the database rows are what the facade shows, in position order" do
    assert_equal ShopItem.in_order.pluck(:key), Prize.all.map(&:key)
    assert_equal ShopItem.active.where.not(kind: "free_signup").in_order.pluck(:key), Prize.paid.map(&:key)
    assert_equal %w[custom_sticker sticker_pack], Prize.paid.first(2).map(&:key), "cheapest first, as the shop always showed them"
  end

  test "a Prize can still be built by hand with the original eight fields" do
    prize = Prize.new(key: "x", name: "X", description: "d", coins: 15, emoji: "x", image: nil, tier: "shop", free_signup: false)
    assert_equal [ true, 0 ], [ prize.active?, prize.position ]
    assert_equal "1.5 hours", prize.hours_text
    assert_equal "0.1 hours", prize.with(coins: 1).hours_text
  end

  test "hours text is also available for a bare price" do
    assert_equal "2 hours", Prize.hours_text_for(20)
    assert_equal "1 hour", Prize.hours_text_for(10)
    assert_equal "1.5 hours", Prize.hours_text_for(15)
    assert_equal "0 hours", Prize.hours_text_for(0)
  end

  test "an archived item leaves paid, active and free_signup but stays in all, keys and find" do
    archive("keychain")
    assert_not_includes Prize.paid.map(&:key), "keychain"
    assert_not_includes Prize.active.map(&:key), "keychain"
    assert_includes Prize.all.map(&:key), "keychain"
    assert_includes Prize.keys, "keychain"
    assert_not_predicate Prize.find("keychain"), :active?

    archive("signup_sticker")
    assert_nil Prize.free_signup
    assert_not_includes Prize.active.map(&:key), "signup_sticker"
    assert_includes Prize.keys, "signup_sticker"
    assert_equal 1, Prize.all.count(&:free_signup?)
  end

  test "stored prize and order keys stay valid for archived items; an unknown key never is" do
    archive("keychain")
    user = users(:onboarded)
    user.update_columns(prize_key: "keychain")
    user.reload
    assert_predicate user, :valid?, "an unchanged stored key is fine"
    user.display_name = "Someone else"
    assert_predicate user, :valid?, "other edits do not trip over the archived pick"

    assert_predicate Order.new(user: user, prize_key: "keychain", prize_name: "Keychain", coins: 30, kind: "purchase", idempotency_key: "k"), :valid?
    assert_not_predicate Order.new(user: user, prize_key: "nope", prize_name: "Nope", coins: 30, kind: "purchase", idempotency_key: "k"), :valid?
  end

  test "choosing an archived item as a NEW pick is refused, an active one is fine" do
    archive("keychain")
    user = users(:new_user)
    user.prize_key = "keychain"
    assert_not user.valid?
    assert_includes user.errors[:prize_key].join, "no longer in the shop"
    user.prize_key = "poster"
    assert_predicate user, :valid?
    user.prize_key = "nope"
    assert_not user.valid?
    user.prize_key = nil
    assert_predicate user, :valid?
  end

  test "a change to an item is visible to the next call, and the catalogue is read once between changes" do
    queries = 0
    counter = ->(*, payload) { queries += 1 if payload[:sql].include?(%(FROM "shop_items")) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      10.times { Prize.paid; Prize.keys; Prize.find("tshirt"); Prize.free_signup }
    end
    assert_operator queries, :<=, 1

    ShopItem.find_by!(key: "tshirt").update!(coins: 55)
    assert_equal 55, Prize.find("tshirt").coins
    ShopItem.find_by!(key: "tshirt").update_columns(coins: 56)
    assert_equal 55, Prize.find("tshirt").coins, "a raw write does not bump the cache: use reload!"
    Prize.reload!
    assert_equal 56, Prize.find("tshirt").coins
  end

  test "the catalogue is cleared by Rails between requests and jobs, through CurrentAttributes" do
    assert_operator ShopItems::Catalogue::Store, :<, ActiveSupport::CurrentAttributes
    Prize.all
    assert_not_nil ShopItems::Catalogue::Store.items
    ShopItems::Catalogue::Store.reset
    assert_nil ShopItems::Catalogue::Store.items
  end

  test "an uploaded picture shows as the item's image path, nil without one" do
    processed = ShipImages::Processor.call(upload_file(png_bytes(30, 30)), config: ShopItems::Config.current)
    item = ShopItem.find_by!(key: "tshirt")
    item.attach_image(processed)
    item.save!
    assert_equal item.reload.image_path, Prize.find("tshirt").image
    assert_nil Prize.find("keychain").image
  end

  test "with the table missing the facade falls back to config/prizes.yml, flags and all" do
    with_table_missing do
      Prize.reload!
      assert_equal Rails.application.config_for(:prizes)[:prizes].map { |entry| entry[:key] }.sort, Prize.keys.sort
      assert_equal "signup_sticker", Prize.free_signup.key
      assert_equal %w[custom_sticker sticker_pack], Prize.paid.first(2).map(&:key)
      assert_equal "5 hours", Prize.find("tshirt").hours_text
      assert(Prize.all.all?(&:active?))
    end
    Prize.reload!
  end

  test "with the table empty (not seeded yet) the facade also falls back to the YAML" do
    ShopItem.delete_all
    Prize.reload!
    assert_includes Prize.keys, "tshirt"
    assert_equal "signup_sticker", Prize.free_signup.key
  end

  test "with no database at all the facade falls back instead of raising" do
    with_table_missing(ActiveRecord::ConnectionNotEstablished) do
      Prize.reload!
      assert_includes Prize.keys, "tshirt"
    end
    Prize.reload!
  end

  test "the original catalogue assertions still hold for the seeded data" do
    assert_operator Prize.all.size, :>=, 8
    assert_equal Prize.keys.uniq, Prize.keys
    Prize.all.each do |prize|
      assert_kind_of Integer, prize.coins
      assert_operator prize.coins, :>=, 0
    end
    assert_not_includes Prize.members, :price_usd
    assert_not_includes Prize.members, :hours
    assert_empty Prize.paid.select { |prize| prize.coins.zero? }
  end

  test "feature flags are unaffected by the catalogue" do
    Flipper.enable(:merch_track)
    assert Features.enabled?(:merch_track)
    archive("keychain")
    assert Features.enabled?(:merch_track)
    assert_not Features.enabled?(:plinko)
  ensure
    Flipper.disable(:merch_track)
  end

  private

  # Makes ShopItem.table_exists? answer "no" (or fail as a down database would) for the block.
  def with_table_missing(error = nil)
    ShopItem.define_singleton_method(:table_exists?) { error ? raise(error) : false }
    yield
  ensure
    ShopItem.singleton_class.remove_method(:table_exists?)
  end
end
