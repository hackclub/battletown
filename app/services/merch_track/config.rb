module MerchTrack
  # Tunables from config/game.yml under `merch_track:`, validated once. Read through `MerchTrack::Config.current`;
  # tests build variants with `Config.from_hash(...)` or `current.with(...)`.
  class Config < Data.define(:days_required, :claim_requires_ship, :after_last_week, :items)
    # One reward. `key` is stored on the claim; `name` is copied onto it so a retired item still reads properly.
    Item = Data.define(:key, :name, :description, :emoji)

    AFTER_LAST = %w[none repeat_last].freeze
    KEY_FORMAT = /\A[a-z0-9_]{1,60}\z/
    NAME_MAX = 60
    DESCRIPTION_MAX = 160

    def self.current
      @current ||= from_hash(Rails.application.config_for(:game))
    end

    def self.reset!
      @current = nil
    end

    def self.from_hash(hash)
      raw = hash.fetch(:merch_track)
      days = raw.fetch(:days_required)
      raise ArgumentError, "game.yml: merch_track.days_required must be an integer from 1 to 7" unless days.is_a?(Integer) && (1..7).cover?(days)

      ship = raw.fetch(:claim_requires_ship)
      raise ArgumentError, "game.yml: merch_track.claim_requires_ship must be true or false" unless [ true, false ].include?(ship)

      after = raw.fetch(:after_last_week).to_s
      raise ArgumentError, "game.yml: merch_track.after_last_week must be one of #{AFTER_LAST.join(', ')}" unless AFTER_LAST.include?(after)

      new(days_required: days, claim_requires_ship: ship, after_last_week: after, items: build_items(raw.fetch(:week_items)))
    end

    def self.build_items(list)
      raise ArgumentError, "game.yml: merch_track.week_items needs at least one item" unless list.is_a?(Array) && list.any?

      items = list.map do |row|
        item = Item.new(key: row.fetch(:key).to_s, name: row.fetch(:name).to_s.squish, description: row.fetch(:description).to_s.squish,
                        emoji: row[:emoji].to_s)
        raise ArgumentError, "game.yml: merch_track item key #{item.key.inspect} is not lowercase letters, digits and underscores" unless item.key.match?(KEY_FORMAT)
        raise ArgumentError, "game.yml: merch_track item #{item.key} needs a name of up to #{NAME_MAX} characters" unless (1..NAME_MAX).cover?(item.name.length)
        raise ArgumentError, "game.yml: merch_track item #{item.key} description is too long" if item.description.length > DESCRIPTION_MAX

        item
      end
      raise ArgumentError, "game.yml: merch_track item keys must be unique" unless items.map(&:key).uniq.size == items.size

      items.freeze
    end
    private_class_method :build_items

    # The item for the Nth boss week (0 is the first), or nil when the week is past the list and `after_last_week` is none.
    def item_for(index)
      return nil if index.negative?
      return items[index] if index < items.size

      items.last if after_last_week == "repeat_last"
    end

    def item_by_key(key) = items.find { |item| item.key == key }
  end
end
