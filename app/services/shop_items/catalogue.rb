module ShopItems
  # Where `Prize` gets its items: the shop_items table, read once per request (or job) and remembered in
  # ActiveSupport::CurrentAttributes, which Rails clears at the start and end of every request and job. So a page that asks for
  # the catalogue ten times runs one query, a new request always sees what staff last saved, and a change made in this very
  # request (ShopItem after_commit) is visible straight away. No picture bytes are ever loaded here.
  #
  # Falls back to config/prizes.yml (ShopItems::Seed.rows) when the table does not exist yet or has no rows, so boot,
  # `assets:precompile`, `db:prepare` and a fresh database nobody has seeded still have a catalogue.
  module Catalogue
    class Store < ActiveSupport::CurrentAttributes
      attribute :items
    end

    module_function

    def items
      Store.items ||= load_items.freeze
    end

    def reset
      Store.reset
    end

    def load_items
      rows = table_rows
      rows.empty? ? Seed.rows.map { |attributes| from_attributes(attributes) } : rows.map { |item| from_item(item) }
    end

    # nil-safe: a database that is down or has no such table gives no rows (so the YAML is used), never an error.
    def table_rows
      return [] unless ShopItem.table_exists?

      ShopItem.without_content.in_order.to_a
    rescue ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished, ActiveRecord::DatabaseConnectionError
      []
    end

    def from_item(item)
      Prize.new(key: item.key, name: item.name, description: item.description, coins: item.coins, emoji: item.emoji,
                image: item.image_path, tier: item.tier, free_signup: item.free_signup?, active: item.active, position: item.position)
    end

    def from_attributes(attributes)
      Prize.new(key: attributes[:key], name: attributes[:name], description: attributes[:description], coins: attributes[:coins],
                emoji: attributes[:emoji], image: nil, tier: attributes[:tier], free_signup: attributes[:kind] == "free_signup",
                active: true, position: attributes[:position])
    end
  end
end
