require "bigdecimal"

module Teams
  # Tunables from config/game.yml under `team:`. Read through `Teams::Config.current`; the percentage becomes basis points
  # (1 bp = 0.01%) once, here, so the maths that follows is integer only.
  Config = Data.define(:max_size, :bonus_bps, :leave_cooldown_seconds, :invite_ttl_seconds, :pay_pending_days) do
    def self.current
      @current ||= from_hash(Rails.application.config_for(:game).fetch(:team))
    end

    def self.reset!
      @current = nil
    end

    def self.from_hash(raw)
      new(
        max_size: integer(raw.fetch(:max_size), "team.max_size", 2..50),
        bonus_bps: bps(raw.fetch(:bonus_percent)),
        leave_cooldown_seconds: integer(raw.fetch(:leave_cooldown_hours), "team.leave_cooldown_hours", 0..24 * 365) * 3600,
        invite_ttl_seconds: integer(raw.fetch(:invite_ttl_hours), "team.invite_ttl_hours", 1..24 * 365) * 3600,
        pay_pending_days: integer(raw.fetch(:pay_pending_days), "team.pay_pending_days", 1..365)
      )
    end

    def self.integer(value, name, allowed)
      raise ArgumentError, "game.yml: #{name} must be a whole number from #{allowed.min} to #{allowed.max}" unless value.is_a?(Integer) && allowed.cover?(value)

      value
    end

    def self.bps(percent)
      scaled = BigDecimal(percent.to_s) * 100
      raise ArgumentError, "game.yml: team.bonus_percent needs at most two decimals and a value from 0 to 100" unless scaled == scaled.round && (0..10_000).cover?(scaled.to_i)

      scaled.to_i
    end
    private_class_method :integer, :bps
  end
end
