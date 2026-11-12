module Orders
  # Typed view of config/orders.yml. `Config.current` is memoised; build a variant with `current.with(...)` in tests.
  Carrier = Data.define(:key, :name, :url)

  Config = Data.define(:overdue_days, :max_open_requested, :orders_per_hour, :staff_actions_per_minute, :exports_per_10_minutes,
                       :export_max_rows, :note_max, :reason_codes, :carriers, :address_retention_days, :address_offer_minutes,
                       :address_reveals_per_hour, :address_lookups_per_10_minutes, :address_notice) do
    def self.current
      @current ||= from_hash(Rails.application.config_for(:orders))
    end

    def self.reset!
      @current = nil
    end

    def self.from_hash(hash)
      reasons = hash.fetch(:reason_codes).to_h { |key, label| [ key.to_s, label.to_s ] }
      raise ArgumentError, "orders.yml: reason_codes keys must be lower-case words" unless reasons.keys.all? { |key| key.match?(/\A[a-z_]{2,30}\z/) }

      carriers = hash.fetch(:carriers).to_h do |key, spec|
        raise ArgumentError, "orders.yml: carrier keys must be lower-case words" unless key.to_s.match?(/\A[a-z_]{2,20}\z/)

        [ key.to_s, Carrier.new(key: key.to_s, name: spec.fetch(:name).to_s, url: spec[:url].presence&.to_s) ]
      end
      new(
        overdue_days: hash.fetch(:overdue_days).to_i.clamp(1, 365),
        max_open_requested: hash.fetch(:max_open_requested).to_i.clamp(1, 100),
        orders_per_hour: hash.fetch(:orders_per_hour).to_i.clamp(1, 1000),
        staff_actions_per_minute: hash.fetch(:staff_actions_per_minute).to_i.clamp(1, 1000),
        exports_per_10_minutes: hash.fetch(:exports_per_10_minutes).to_i.clamp(1, 100),
        export_max_rows: hash.fetch(:export_max_rows).to_i.clamp(1, 100_000),
        note_max: hash.fetch(:note_max).to_i.clamp(1, OrderEvent::NOTE_MAX),
        reason_codes: reasons.freeze,
        carriers: carriers.freeze,
        address_retention_days: hash.fetch(:address_retention_days).to_i.clamp(1, 365),
        address_offer_minutes: hash.fetch(:address_offer_minutes).to_i.clamp(1, 120),
        address_reveals_per_hour: hash.fetch(:address_reveals_per_hour).to_i.clamp(1, 1000),
        address_lookups_per_10_minutes: hash.fetch(:address_lookups_per_10_minutes).to_i.clamp(1, 100),
        address_notice: hash.fetch(:address_notice).to_s.squish
      )
    end

    # The privacy notice with the retention period filled in.
    def address_notice_text = address_notice.gsub("{days}", address_retention_days.to_s)

    def reason_label(code) = reason_codes[code.to_s]

    def carrier(key) = carriers[key.to_s]
  end
end
