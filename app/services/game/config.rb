require "bigdecimal"

module Game
  # Typed view of config/game.yml (coins and streaks keys). Everything is converted once, here, into integers so the
  # arithmetic that follows never touches a float: the multiplier becomes thousandths, the ramp becomes basis points
  # (1 bp = 0.01%). `Config.current` is memoised; build a variant with `current.with(...)` (tests do).
  Config = Data.define(:coins_per_hour, :deflation_after_seconds, :deflation_multiplier_milli, :quick_seconds,
                       :goal_seconds, :grace_seconds, :freeze_regen_days, :freeze_starts_available, :ramp_bps) do
    def self.current
      @current ||= from_hash(Rails.application.config_for(:game))
    end

    def self.reset!
      @current = nil
    end

    def self.from_hash(hash)
      coins = hash.fetch(:coins)
      streaks = hash.fetch(:streaks)
      new(
        coins_per_hour: positive_integer(coins.fetch(:per_approved_hour), "coins.per_approved_hour"),
        deflation_after_seconds: positive_integer(coins.fetch(:deflation_after_hours), "coins.deflation_after_hours") * 3600,
        deflation_multiplier_milli: scaled(coins.fetch(:deflation_multiplier), 1000, "coins.deflation_multiplier", 1..1000),
        quick_seconds: positive_integer(streaks.fetch(:quick_minutes), "streaks.quick_minutes") * 60,
        goal_seconds: positive_integer(streaks.fetch(:goal_minutes), "streaks.goal_minutes") * 60,
        grace_seconds: non_negative_integer(streaks.fetch(:grace_hours), "streaks.grace_hours") * 3600,
        freeze_regen_days: positive_integer(streaks.fetch(:freeze_regen_days), "streaks.freeze_regen_days"),
        freeze_starts_available: streaks.fetch(:freeze_starts_available) == true,
        ramp_bps: Array(streaks.fetch(:ramp_percent)).map { |percent| scaled(percent, 100, "streaks.ramp_percent", 0..10_000) }.freeze
      ).tap { |config| raise ArgumentError, "game.yml: streaks.ramp_percent needs at least one value" if config.ramp_bps.empty? }
    end

    # "8.1" (or the float 8.1 from YAML) times 100, exactly, via BigDecimal; never a float multiplication.
    def self.scaled(value, factor, name, allowed)
      scaled = (BigDecimal(value.to_s) * factor)
      raise ArgumentError, "game.yml: #{name} #{value.inspect} has more precision than supported" unless scaled == scaled.round
      raise ArgumentError, "game.yml: #{name} #{value.inspect} is out of range" unless allowed.cover?(scaled.to_i)
      scaled.to_i
    end

    def self.positive_integer(value, name)
      raise ArgumentError, "game.yml: #{name} must be a positive integer" unless value.is_a?(Integer) && value.positive?
      value
    end

    def self.non_negative_integer(value, name)
      raise ArgumentError, "game.yml: #{name} must be a non-negative integer" unless value.is_a?(Integer) && !value.negative?
      value
    end
    private_class_method :scaled, :positive_integer, :non_negative_integer
  end
end
