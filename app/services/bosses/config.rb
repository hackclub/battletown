module Bosses
  # Tunables from config/game.yml under `boss:`. Read through `Bosses::Config.current`.
  Config = Data.define(:slayer_seconds, :afterglow_days) do
    def self.current
      @current ||= begin
        raw = Rails.application.config_for(:game).fetch(:boss)
        new(**members.to_h { |key| [ key, Integer(raw.fetch(key)) ] })
      end
    end
  end
end
