module ShipImages
  # Tunables from config/game.yml under `ship_screenshots:`. Read through `ShipImages::Config.current`.
  Config = Data.define(:max_files, :max_upload_bytes, :max_megapixels, :max_edge_px, :webp_quality, :withdrawn_retention_days,
                       :uploads_per_10_minutes) do
    # Room in a whole upload request for the form's text fields and the multipart framing.
    REQUEST_ALLOWANCE = 1.megabyte

    def self.current
      @current ||= from_hash(Rails.application.config_for(:game).fetch(:ship_screenshots))
    end

    def self.reset!
      @current = nil
    end

    def self.from_hash(raw)
      config = new(
        max_files: integer(raw, :max_files),
        max_upload_bytes: integer(raw, :max_upload_bytes),
        max_megapixels: integer(raw, :max_megapixels),
        max_edge_px: integer(raw, :max_edge_px),
        webp_quality: integer(raw, :webp_quality),
        withdrawn_retention_days: integer(raw, :withdrawn_retention_days),
        uploads_per_10_minutes: integer(raw, :uploads_per_10_minutes)
      )
      raise ArgumentError, "game.yml: ship_screenshots.max_files must be between 1 and #{ShipImage::POSITIONS.max}" unless ShipImage::POSITIONS.cover?(config.max_files)
      raise ArgumentError, "game.yml: ship_screenshots.max_upload_bytes must be between 1 and #{ShipImage::MAX_BYTES_CEILING}" unless (1..ShipImage::MAX_BYTES_CEILING).cover?(config.max_upload_bytes)
      raise ArgumentError, "game.yml: ship_screenshots.webp_quality must be between 1 and 100" unless (1..100).cover?(config.webp_quality)

      config
    end

    def self.integer(raw, key)
      value = Integer(raw.fetch(key).to_s, 10, exception: false)
      raise ArgumentError, "game.yml: ship_screenshots.#{key} must be a positive whole number" unless value&.positive?

      value
    end

    def max_pixels = max_megapixels * 1_000_000

    # The largest request body a ship form post may carry (every slot full, plus text).
    def max_request_bytes = (max_files * max_upload_bytes) + REQUEST_ALLOWANCE
  end
end
