module ShopItems
  # Tunables from config/game.yml under `shop_items:`. Read through `ShopItems::Config.current`. It answers the same questions
  # as ShipImages::Config (max_upload_bytes, max_pixels, max_edge_px, webp_quality), so ShipImages::Processor can use it.
  Config = Data.define(:max_upload_bytes, :max_megapixels, :max_edge_px, :webp_quality) do
    # Room in a whole upload request for the form's text fields and the multipart framing.
    REQUEST_ALLOWANCE = 64.kilobytes

    def self.current
      @current ||= from_hash(Rails.application.config_for(:game).fetch(:shop_items))
    end

    def self.reset!
      @current = nil
    end

    def self.from_hash(raw)
      config = new(max_upload_bytes: integer(raw, :max_upload_bytes), max_megapixels: integer(raw, :max_megapixels),
                   max_edge_px: integer(raw, :max_edge_px), webp_quality: integer(raw, :webp_quality))
      raise ArgumentError, "game.yml: shop_items.max_upload_bytes must be between 1 and #{ShipImage::MAX_BYTES_CEILING}" unless (1..ShipImage::MAX_BYTES_CEILING).cover?(config.max_upload_bytes)
      raise ArgumentError, "game.yml: shop_items.webp_quality must be between 1 and 100" unless (1..100).cover?(config.webp_quality)

      config
    end

    def self.integer(raw, key)
      value = Integer(raw.fetch(key).to_s, 10, exception: false)
      raise ArgumentError, "game.yml: shop_items.#{key} must be a positive whole number" unless value&.positive?

      value
    end

    def max_pixels = max_megapixels * 1_000_000

    # What the Processor calls the thing in its "too big" message.
    def picture_noun = "picture"

    # The largest admin request body that may carry one picture.
    def max_request_bytes = max_upload_bytes + REQUEST_ALLOWANCE
  end
end
