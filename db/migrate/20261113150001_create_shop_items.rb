# The shop catalogue, in the database so staff can change an item, a price or a picture without a deploy (/admin/shop).
# Nothing here is about a person, so it does not reference users. `orders.prize_key` and `users.prize_key` still hold the
# item's key as text: an archived item (active = false) keeps its row and key, so those stay valid. The key never changes.
#
# The picture is the re-encoded WebP that ShipImages::Processor produces (the original upload is never kept). Its bytes
# live in this table; list queries leave the column out (ShopItem.without_content).
#
# The first rows come from config/prizes.yml (the default seed): the last step of `up` loads them, skipping any key that
# already exists, so running it again or editing an item later never gets overwritten.
class CreateShopItems < ActiveRecord::Migration[8.1]
  def up
    create_table :shop_items do |t|
      t.string :key, null: false, limit: 60
      t.string :name, null: false, limit: 60
      t.string :description, null: false, limit: 200, default: ""
      t.string :emoji, limit: 8
      t.integer :coins, null: false
      t.string :tier, null: false, default: "shop"
      t.string :kind, null: false, default: "regular"
      t.integer :position, null: false, default: 0
      t.boolean :active, null: false, default: true
      t.binary :image_content
      t.integer :image_width
      t.integer :image_height
      t.integer :image_byte_size
      t.string :image_sha256, limit: 64
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end

    add_index :shop_items, :key, unique: true
    add_index :shop_items, [ :active, :position ]
    # At most one free signup item (the sticker every new person can claim).
    add_index :shop_items, :kind, unique: true, where: "kind = 'free_signup'", name: "index_shop_items_one_free_signup"

    add_check_constraint :shop_items, "key ~ '^[a-z0-9_]{1,60}$'", name: "shop_items_key_check"
    add_check_constraint :shop_items, "char_length(btrim(name)) BETWEEN 1 AND 60", name: "shop_items_name_check"
    add_check_constraint :shop_items, "char_length(description) <= 200", name: "shop_items_description_check"
    add_check_constraint :shop_items, "emoji IS NULL OR char_length(emoji) BETWEEN 1 AND 8", name: "shop_items_emoji_check"
    add_check_constraint :shop_items, "coins >= 0", name: "shop_items_coins_check"
    add_check_constraint :shop_items, "tier IN ('daily', 'weekly', 'shop')", name: "shop_items_tier_check"
    add_check_constraint :shop_items, "kind IN ('regular', 'free_signup')", name: "shop_items_kind_check"
    # A bought item costs coins (an order for a purchase must be more than 0); the free signup item is always free.
    add_check_constraint :shop_items, "(kind = 'free_signup' AND coins = 0) OR (kind = 'regular' AND coins > 0)", name: "shop_items_kind_coins_check"
    add_check_constraint :shop_items, "position >= 0", name: "shop_items_position_check"
    # A picture is all or nothing, no bigger than ship screenshots may be, and really is a WebP file (RIFF....WEBP).
    add_check_constraint :shop_items,
                         "(image_content IS NULL AND image_width IS NULL AND image_height IS NULL AND image_byte_size IS NULL AND image_sha256 IS NULL) OR " \
                         "(image_content IS NOT NULL AND image_width > 0 AND image_height > 0 AND image_byte_size BETWEEN 1 AND 5000000 AND " \
                         "octet_length(image_content) = image_byte_size AND image_sha256 ~ '^[0-9a-f]{64}$' AND " \
                         "substring(image_content from 1 for 4) = '\\x52494646'::bytea AND substring(image_content from 9 for 4) = '\\x57454250'::bytea)",
                         name: "shop_items_image_check"

    ShopItems::Seed.call
  end

  def down
    drop_table :shop_items
  end
end
