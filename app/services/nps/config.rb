module Nps
  # Tunables from config/game.yml under `nps:`. Read through `Nps::Config.current` (memoised; `current.with(...)` builds a
  # variant for a test). Every value is a positive whole number.
  Config = Data.define(:active_seconds, :active_days, :interval_days, :cooldown_days, :max_unanswered, :idle_days_reset,
                       :token_ttl_days, :comment_retention_days) do
    def self.current
      @current ||= from_hash(Rails.application.config_for(:game).fetch(:nps))
    end

    def self.reset!
      @current = nil
    end

    def self.from_hash(raw)
      new(
        active_seconds: positive(raw, :active_minutes) * 60,
        active_days: positive(raw, :active_days),
        interval_days: positive(raw, :interval_days),
        cooldown_days: positive(raw, :cooldown_days_after_answer),
        max_unanswered: positive(raw, :max_prompts_without_answer),
        idle_days_reset: positive(raw, :idle_days_reset),
        token_ttl_days: positive(raw, :token_ttl_days),
        comment_retention_days: positive(raw, :comment_retention_days)
      )
    end

    def self.positive(raw, key)
      value = Integer(raw.fetch(key))
      raise ArgumentError, "game.yml: nps.#{key} must be a positive whole number" unless value.positive?

      value
    end
    private_class_method :positive

    def token_ttl = token_ttl_days.days
  end
end
