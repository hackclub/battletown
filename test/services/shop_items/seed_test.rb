require "rake"
require "test_helper"

class ShopItems::SeedTest < ActiveSupport::TestCase
  YAML_KEYS = Rails.application.config_for(:prizes)[:prizes].map { |entry| entry[:key] }.freeze

  test "the rows come from config/prizes.yml: paid items by price then name, then the free sticker, positions 1..n" do
    rows = ShopItems::Seed.rows
    assert_equal YAML_KEYS.sort, rows.map { |row| row[:key] }.sort
    assert_equal (1..rows.size).to_a, rows.map { |row| row[:position] }
    assert_equal "signup_sticker", rows.last[:key]
    assert_equal "free_signup", rows.last[:kind]
    assert_equal 0, rows.last[:coins]
    paid = rows[0...-1]
    assert_equal paid.sort_by { |row| [ row[:coins], row[:name] ] }, paid
    assert(rows.all? { |row| row[:active] })
    rows.each do |row|
      item = ShopItem.new(row)
      item.valid? # the key is taken by the fixture of the same name, and the sticker by the existing sticker: nothing else may fail
      assert_empty item.errors.attribute_names - %i[key base], row[:key]
    end
  end

  test "importing into an empty table adds every item and returns the count" do
    ShopItem.delete_all
    assert_equal YAML_KEYS.size, ShopItems::Seed.call
    assert_equal YAML_KEYS.sort, ShopItem.pluck(:key).sort
    assert_equal 1, ShopItem.where(kind: "free_signup").count
    assert_equal ShopItems::Seed.rows.map { |row| [ row[:key], row[:position] ] }.sort, ShopItem.pluck(:key, :position).sort
  end

  test "importing again changes nothing" do
    before = ShopItem.order(:key).pluck(:key, :name, :coins, :position, :updated_at)
    assert_equal 0, ShopItems::Seed.call
    assert_equal 0, ShopItems::Seed.call
    assert_equal before, ShopItem.order(:key).pluck(:key, :name, :coins, :position, :updated_at)
  end

  test "it never overwrites an edited item, an archived one or one with a picture" do
    item = ShopItem.find_by!(key: "tshirt")
    item.update!(name: "Edited tee", coins: 77, description: "Mine", active: false, emoji: "🎽", tier: "weekly")
    sticker = ShopItem.find_by!(key: "signup_sticker")
    sticker.update!(name: "My sticker")
    assert_equal 0, ShopItems::Seed.call
    item.reload
    assert_equal [ "Edited tee", 77, "Mine", false, "🎽", "weekly" ], [ item.name, item.coins, item.description, item.active, item.emoji, item.tier ]
    assert_equal "My sticker", sticker.reload.name
  end

  test "it adds only the keys that are missing, after the existing items, and leaves the rest" do
    ShopItem.where(key: %w[poster keychain]).delete_all
    top = ShopItem.maximum(:position)
    ShopItem.find_by!(key: "tshirt").update!(coins: 61)
    assert_equal 2, ShopItems::Seed.call
    assert_equal 61, ShopItem.find_by!(key: "tshirt").coins
    added = ShopItem.where(key: %w[poster keychain]).order(:position)
    assert_equal 2, added.size
    assert(added.all? { |item| item.position > top }, "new items go after the existing ones")
    assert_equal added.map(&:position).uniq, added.map(&:position)
  end

  test "it does not add a second free item when a different one already exists" do
    ShopItem.where(key: "signup_sticker").delete_all
    ShopItem.create!(key: "my_free_thing", name: "Free thing", coins: 0, kind: "free_signup", tier: "daily", position: 99)
    assert_nothing_raised { ShopItems::Seed.call }
    assert_equal [ "my_free_thing" ], ShopItem.where(kind: "free_signup").pluck(:key)
    assert_equal 0, ShopItem.where(key: "signup_sticker").count
  end

  test "the rake task adds the missing defaults and says how many" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("shop_items:import")
    ShopItem.where(key: %w[poster keychain]).delete_all
    out, = capture_io { Rake::Task["shop_items:import"].execute }
    assert_equal "shop_items:import added=2 total=#{YAML_KEYS.size}\n", out
    out, = capture_io { Rake::Task["shop_items:import"].execute }
    assert_equal "shop_items:import added=0 total=#{YAML_KEYS.size}\n", out
  end

  test "the rake task, db:seed and the migration use the same service" do
    assert_includes Rails.root.join("lib/tasks/shop_items.rake").read, "ShopItems::Seed.call"
    assert_includes Rails.root.join("db/seeds.rb").read, "ShopItems::Seed.call"
    assert_includes Rails.root.join("db/migrate/20261113150001_create_shop_items.rb").read, "ShopItems::Seed.call"
  end

  test "the facade shows the seeded items in the order the shop always had" do
    ShopItem.delete_all
    ShopItems::Seed.call
    Prize.reload!
    assert_equal YAML_KEYS.sort, Prize.keys.sort
    assert_equal Prize.paid.sort_by { |prize| [ prize.coins, prize.name ] }.map(&:key), Prize.paid.map(&:key)
  end

  test "config/prizes.yml holds coin prices only: no dollar figures, no shipping or cost fields" do
    text = Rails.root.join("config/prizes.yml").read
    assert_not_includes text, "$"
    assert_no_match(/usd|dollar|price_usd|shipping|budget|cost/i, text)
    Rails.application.config_for(:prizes)[:prizes].each do |entry|
      assert_empty entry.keys - %i[key name description coins emoji image tier free_signup], entry[:key]
    end
  end

  test "the YAML says it is only the default seed" do
    text = Rails.root.join("config/prizes.yml").read
    assert_match(/DEFAULT SEED/, text)
    assert_match(/PLACEHOLDER/, text)
    assert_match(%r{/admin/shop}, text)
  end

  test "no game config or shop view holds a dollar figure either" do
    shop_config = Rails.application.config_for(:game).fetch(:shop_items)
    assert_equal %i[max_upload_bytes max_megapixels max_edge_px webp_quality], shop_config.keys
    Dir[Rails.root.join("app/views/admin/shop_items/*").to_s].each do |path|
      assert_no_match(/\$\d|dollar|usd/i, File.read(path), path)
    end
  end
end

class ShopItems::ConfigTest < ActiveSupport::TestCase
  test "limits come from game.yml and are within the database ceiling" do
    config = ShopItems::Config.current
    assert_operator config.max_upload_bytes, :<=, ShipImage::MAX_BYTES_CEILING
    assert_equal config.max_megapixels * 1_000_000, config.max_pixels
    assert_operator config.max_request_bytes, :>, config.max_upload_bytes
    assert_equal "picture", config.picture_noun
  end

  test "bad values are refused" do
    raw = Rails.application.config_for(:game).fetch(:shop_items)
    assert_raises(ArgumentError) { ShopItems::Config.from_hash(raw.merge(max_upload_bytes: 5_000_001)) }
    assert_raises(ArgumentError) { ShopItems::Config.from_hash(raw.merge(webp_quality: 101)) }
    assert_raises(ArgumentError) { ShopItems::Config.from_hash(raw.merge(max_edge_px: 0)) }
    assert_raises(ArgumentError) { ShopItems::Config.from_hash(raw.merge(max_megapixels: "lots")) }
  end
end
