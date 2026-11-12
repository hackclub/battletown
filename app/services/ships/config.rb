require "bigdecimal"

module Ships
  # Tunables from config/game.yml under `ships:`. Read through `Ships::Config.current`; every value is converted
  # once into integer seconds (the hours are decimals in the file, never floats at run time).
  Config = Data.define(:min_seconds, :step_seconds, :rejection_reasons) do
    def self.current
      @current ||= from_hash(Rails.application.config_for(:game).fetch(:ships))
    end

    def self.reset!
      @current = nil
    end

    def self.from_hash(raw)
      step = seconds(raw.fetch(:approval_step_hours), "ships.approval_step_hours")
      min = seconds(raw.fetch(:min_hours), "ships.min_hours")
      raise ArgumentError, "game.yml: ships.min_hours must be at least one second" unless min.positive?
      raise ArgumentError, "game.yml: ships.approval_step_hours must be at least one second" unless step.positive?

      reasons = Array(raw.fetch(:rejection_reasons)).map { |reason| reason.to_s.squish }.reject(&:empty?)
      raise ArgumentError, "game.yml: ships.rejection_reasons entries must be at most #{Ship::REASON_MAX} characters" if reasons.any? { |r| r.length > Ship::REASON_MAX }

      new(min_seconds: min, step_seconds: step, rejection_reasons: reasons.freeze)
    end

    def self.seconds(hours, name)
      value = BigDecimal(hours.to_s) * 3600
      raise ArgumentError, "game.yml: #{name} must be a whole number of seconds when converted" unless value.frac.zero? && !value.negative?

      value.to_i
    end
  end
end
