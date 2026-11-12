module ShopItems
  # Loads the default catalogue from config/prizes.yml into the shop_items table. That file is ONLY the default seed (and the
  # fallback while the table is missing or empty): once an item is in the table, staff own it at /admin/shop.
  #
  # Idempotent and never destructive: an item whose key already exists is left exactly as it is (an edited price, name or
  # picture is never overwritten, an archived item stays archived), and only missing keys are added. Run by the migration that
  # creates the table, by `db:seed` and by `bin/rails shop_items:import`.
  #
  # Order: the paid items by price then name (the order the shop has always shown), then the free sticker. Positions run 1..n.
  module Seed
    module_function

    # The attribute hashes for every item in the YAML, ready for ShopItem. `image` in the YAML is ignored: pictures are
    # uploaded in the admin (and stored in the database), not named in a file.
    def rows
      entries = Rails.application.config_for(:prizes).fetch(:prizes).map(&:to_h)
      free, paid = entries.partition { |entry| entry[:free_signup] }
      (paid.sort_by { |entry| [ entry[:coins], entry[:name] ] } + free).each_with_index.map do |entry, index|
        { key: entry.fetch(:key), name: entry.fetch(:name), description: entry[:description].to_s, emoji: entry[:emoji],
          coins: entry.fetch(:coins), tier: entry.fetch(:tier, "shop"), kind: entry[:free_signup] ? "free_signup" : "regular",
          position: index + 1, active: true }
      end
    end

    # Adds the missing items and returns how many it added.
    def call
      ShopItem.reset_column_information
      existing = ShopItem.pluck(:key)
      offset = ShopItem.maximum(:position).to_i
      missing = rows.reject { |row| existing.include?(row[:key]) }
      missing = missing.reject { |row| row[:kind] == "free_signup" } if ShopItem.exists?(kind: "free_signup")
      return 0 if missing.empty?

      missing.each do |row|
        item = ShopItem.new(row.merge(position: row[:position] + offset))
        raise ArgumentError, "config/prizes.yml: #{row[:key]}: #{item.errors.full_messages.to_sentence}" unless item.valid?
      end
      ShopItem.insert_all(missing.map { |row| row.merge(position: row[:position] + offset) }, unique_by: :key).length.tap { Prize.reload! }
    end
  end
end
