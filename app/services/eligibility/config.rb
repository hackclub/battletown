module Eligibility
  # Tunables from config/game.yml under `eligibility:` (only read while the `eligibility_gate` flag is on). Read through
  # `Eligibility::Config.current`.
  #   verification_max_age_days: how long a sign-in's copy of the Hack Club Auth verification counts as fresh.
  #   help_line: the neutral "who to ask" sentence shown next to the not-eligible note. A placeholder the owner edits.
  Config = Data.define(:verification_max_age_days, :help_line) do
    def self.current
      @current ||= from_hash(Rails.application.config_for(:game).fetch(:eligibility))
    end

    def self.reset!
      @current = nil
    end

    def self.from_hash(raw)
      days = Integer(raw.fetch(:verification_max_age_days))
      raise ArgumentError, "game.yml: eligibility.verification_max_age_days must be a positive whole number" unless days.positive?

      line = raw.fetch(:help_line).to_s.squish
      raise ArgumentError, "game.yml: eligibility.help_line must be one short sentence (at most 200 characters)" if line.empty? || line.length > 200

      new(verification_max_age_days: days, help_line: line)
    end

    def max_age = verification_max_age_days.days
  end
end
