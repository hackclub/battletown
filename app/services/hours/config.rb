module Hours
  # Tunables from config/game.yml under `hours:`. Read through `Hours::Config.current`.
  Config = Data.define(:daily_cap_seconds, :max_backfill_days, :active_seconds, :days_before_signup_counted) do
    def self.current
      @current ||= begin
        raw = Rails.application.config_for(:game).fetch(:hours)
        new(**members.to_h { |key| [ key, Integer(raw.fetch(key)) ] })
      end
    end
  end
end
