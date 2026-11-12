module AdminUsers
  # Limits from config/game.yml under `admin_users:`. Read through `AdminUsers::Config.current`.
  Config = Data.define(:max_adjust_coins, :max_adjust_minutes, :view_audit_minutes) do
    def self.current
      @current ||= begin
        raw = Rails.application.config_for(:game).fetch(:admin_users)
        config = new(**members.to_h { |key| [ key, Integer(raw.fetch(key)) ] })
        raise ArgumentError, "game.yml: admin_users.max_adjust_minutes can be at most #{HourEntry::MAX_SECONDS / 60}" if config.max_adjust_minutes > HourEntry::MAX_SECONDS / 60
        raise ArgumentError, "game.yml: admin_users limits must be at least 1" if config.to_h.values.any? { |value| value < 1 }

        config
      end
    end

    def self.reset! = @current = nil

    def view_audit_window = view_audit_minutes.minutes
  end
end
