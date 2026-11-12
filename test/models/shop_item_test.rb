require "test_helper"
require_relative "../support/ship_images_helper"

class ShopItemTest < ActiveSupport::TestCase
  include ShipImagesHelper

  def build(**attributes)
    ShopItem.new({ key: "pixel_pin", name: "Pixel pin", description: "A tiny pin.", emoji: "📌", coins: 25, tier: "shop", kind: "regular", position: 50 }.merge(attributes))
  end

  def processed(bytes = png_bytes(40, 20))
    ShipImages::Processor.call(upload_file(bytes), config: ShopItems::Config.current)
  end

  # Runs a statement the database should refuse. A savepoint keeps the test's transaction usable after the error.
  def db_refuses(message = nil, error = ActiveRecord::StatementInvalid, &block)
    assert_raises(*[ error, message ].compact) { ShopItem.transaction(requires_new: true, &block) }
  end

  def raw_insert(**columns)
    row = { key: "raw_item", name: "Raw", description: "", coins: 5, tier: "shop", kind: "regular", position: 1, active: true,
            created_at: Time.current, updated_at: Time.current }.merge(columns)
    ShopItem.insert_all!([ row ])
  end

  # --- validations ---

  test "a normal item is valid and saved with its defaults" do
    item = build
    assert_predicate item, :valid?
    item.save!
    assert_equal 0, item.lock_version
    assert item.active
  end

  test "the key is lowercase letters, digits and underscores, 1 to 60, and unique" do
    [ "", "Has-Caps", "has space", "dash-ed", "ünï", "a" * 61, "semi;colon" ].each do |key|
      assert_not build(key: key).valid?, "#{key.inspect} must be refused"
    end
    [ "a", "a_1", "z" * 60, "0" ].each { |key| assert build(key: key).valid?, key }

    build.save!
    duplicate = build(name: "Again")
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:key].join, "already used"
  end

  test "name is required and at most 60 characters; blanks and runs of spaces are tidied" do
    assert_not build(name: "").valid?
    assert_not build(name: "   ").valid?
    assert_not build(name: "n" * 61).valid?
    assert build(name: "n" * 60).valid?
    item = build(name: "  Pixel   pin \n")
    item.valid?
    assert_equal "Pixel pin", item.name
  end

  test "description is at most 200 characters and may be empty" do
    assert build(description: "").valid?
    assert build(description: nil).valid?
    assert build(description: "d" * 200).valid?
    assert_not build(description: "d" * 201).valid?
  end

  test "emoji is optional and at most 8 characters" do
    assert build(emoji: nil).valid?
    assert_nil build(emoji: "   ").tap(&:valid?).emoji
    assert build(emoji: "🏷️").valid?
    assert build(emoji: "e" * 8).valid?
    assert_not build(emoji: "e" * 9).valid?
  end

  test "coins are a whole number, more than 0 for a regular item and 0 for the free signup item" do
    [ 0, -1, 1.5, nil, ShopItem::COINS_MAX + 1 ].each { |coins| assert_not build(coins: coins).valid?, coins.inspect }
    assert build(coins: 1).valid?
    assert build(coins: ShopItem::COINS_MAX).valid?

    ShopItem.where(kind: "free_signup").delete_all
    sticker = build(key: "welcome_sticker", kind: "free_signup", coins: 0)
    assert_predicate sticker, :valid?
    assert_not build(key: "welcome_sticker", kind: "free_signup", coins: 5).valid?
  end

  test "tier and kind must be known" do
    assert_not build(tier: "monthly").valid?
    assert_not build(kind: "gift").valid?
    ShopItem::TIERS.each { |tier| assert build(tier: tier).valid?, tier }
  end

  test "position is a whole number from 0" do
    assert_not build(position: -1).valid?
    assert_not build(position: 1.5).valid?
    assert build(position: 0).valid?
  end

  test "at most one free signup item can exist; the model says so kindly" do
    assert_equal 1, ShopItem.where(kind: "free_signup").count, "the fixtures carry the default sticker"
    second = build(key: "second_sticker", kind: "free_signup", coins: 0)
    assert_not second.valid?
    assert_match(/already a free signup item/, second.errors.full_messages.to_sentence)
  end

  test "the key and the kind cannot be changed once the item exists" do
    item = shop_items(:tshirt)
    assert_raises(ActiveRecord::ReadonlyAttributeError) { item.key = "other" }
    assert_raises(ActiveRecord::ReadonlyAttributeError) { item.kind = "free_signup" }
    assert_raises(ActiveRecord::ActiveRecordError) { item.update_columns(key: "other") }
    assert_equal "tshirt", item.reload.key
    assert_equal 0, ShopItem.where(key: "other").count
  end

  # --- the database says no even when the model is bypassed ---

  test "the database refuses a key that is not lowercase letters, digits and underscores" do
    [ "Bad", "bad-key", "bad key", "", "a" * 61 ].each do |key|
      db_refuses(key.inspect) { raw_insert(key: key) }
    end
  end

  test "the database refuses a bad name, description, emoji, price, tier, kind and position" do
    {
      "blank name" => { name: "  " }, "long description" => { description: "d" * 201 }, "long emoji" => { emoji: "e" * 9 },
      "empty emoji" => { emoji: "" }, "negative coins" => { coins: -1 }, "free regular" => { coins: 0 },
      "unknown tier" => { tier: "monthly" }, "unknown kind" => { kind: "gift" }, "negative position" => { position: -1 },
      "priced free item" => { kind: "free_signup", coins: 3, key: "sticker_two" }
    }.each do |label, columns|
      db_refuses(label) { raw_insert(**columns) }
    end
  end

  test "update_column and raw SQL cannot break the rules either" do
    item = shop_items(:tshirt)
    db_refuses { item.update_columns(coins: -5) }
    db_refuses { item.update_columns(coins: 0) }
    db_refuses { item.update_columns(tier: "weekend") }
    db_refuses { item.update_columns(position: -1) }
    db_refuses { ActiveRecord::Base.connection.execute("UPDATE shop_items SET name = '' WHERE key = 'tshirt'") }
    db_refuses { ActiveRecord::Base.connection.execute("UPDATE shop_items SET kind = 'free_signup', coins = 0 WHERE key = 'tshirt'") }
    assert_equal 50, item.reload.coins
  end

  test "the database allows only one free signup item" do
    db_refuses(nil, ActiveRecord::RecordNotUnique) { raw_insert(key: "another_sticker", kind: "free_signup", coins: 0) }
    assert_equal 1, ShopItem.where(kind: "free_signup").count
  end

  test "the database refuses a duplicate key" do
    db_refuses(nil, ActiveRecord::RecordNotUnique) { raw_insert(key: "tshirt") }
  end

  # --- the picture ---

  test "a processed picture is stored with its size, hash and bytes, and is a WebP" do
    item = build
    item.attach_image(processed)
    item.save!
    item = ShopItem.find(item.id)
    assert_predicate item, :image?
    assert_equal "RIFF", item.image_content.byteslice(0, 4)
    assert_equal [ 40, 20 ], [ item.image_width, item.image_height ]
    assert_equal item.image_content.bytesize, item.image_byte_size
    assert_match(%r{\A/shop/items/pixel_pin/image\?v=#{item.image_sha256.first(12)}\z}, item.image_path)
  end

  test "an item without a picture has no image path" do
    assert_nil shop_items(:tshirt).image_path
    assert_not_predicate shop_items(:tshirt), :image?
  end

  test "removing the picture clears every picture column" do
    item = build
    item.attach_image(processed)
    item.save!
    item.remove_image
    item.save!
    assert_equal [ nil ] * 5, item.reload.attributes.values_at("image_content", "image_width", "image_height", "image_byte_size", "image_sha256")
  end

  test "the database refuses a half-set picture, a lie about its size, a non-WebP and one past the ceiling" do
    item = shop_items(:tshirt)
    good = processed
    db_refuses("all or nothing") { item.update_columns(image_sha256: good.sha256) }
    db_refuses("size must match") do
      item.update_columns(image_content: good.content, image_width: 1, image_height: 1, image_byte_size: good.byte_size + 1, image_sha256: good.sha256)
    end
    db_refuses("not a WebP") do
      item.update_columns(image_content: png_bytes, image_width: 1, image_height: 1, image_byte_size: png_bytes.bytesize, image_sha256: good.sha256)
    end
    db_refuses("bad hash") do
      item.update_columns(image_content: good.content, image_width: 1, image_height: 1, image_byte_size: good.byte_size, image_sha256: "xyz")
    end
    db_refuses("over the ceiling") do
      big = "RIFF".b + "\0\0\0\0".b + "WEBP".b + ("a".b * 5_000_000)
      item.update_columns(image_content: big, image_width: 1, image_height: 1, image_byte_size: big.bytesize, image_sha256: good.sha256)
    end
    assert_not_predicate item.reload, :image?
  end

  test "lists leave the picture bytes out" do
    item = build
    item.attach_image(processed)
    item.save!
    listed = ShopItem.without_content.find_by!(key: "pixel_pin")
    assert_predicate listed, :image?
    assert_raises(ActiveModel::MissingAttributeError) { listed.image_content }
    assert_equal item.image_content, ShopItem.image_content_for("pixel_pin")
    assert_nil ShopItem.image_content_for("tshirt")
  end

  test "optimistic locking: a stale copy cannot overwrite a newer save" do
    first = ShopItem.find_by!(key: "keychain")
    second = ShopItem.find_by!(key: "keychain")
    first.update!(coins: 31)
    second.coins = 99
    assert_raises(ActiveRecord::StaleObjectError) { second.save! }
    assert_equal 31, first.reload.coins
  end

  test "an item holds no user data: no column points at a person" do
    assert_empty ShopItem.column_names.grep(/\Auser|email|slack|\bip\b|hca|identity|address|phone|birth/)
  end
end
