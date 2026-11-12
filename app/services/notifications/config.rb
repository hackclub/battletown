module Notifications
  # Typed view of config/notifications.yml. `Config.current` is memoised; build a variant with `current.with(...)`.
  Config = Data.define(:quiet_start, :quiet_end, :max_attempts, :backoff_base, :backoff_max, :max_lateness,
                       :lease, :batch_size, :retention_days, :templates, :event_max_lateness, :labels) do
    def self.current
      @current ||= from_hash(Rails.application.config_for(:notifications))
    end

    def self.reset!
      @current = nil
    end

    def self.from_hash(hash)
      new(
        quiet_start: minutes_of_day(hash.fetch(:quiet_hours_start)),
        quiet_end: minutes_of_day(hash.fetch(:quiet_hours_end)),
        max_attempts: hash.fetch(:max_attempts).to_i.clamp(1, Notification::MAX_ATTEMPTS),
        backoff_base: hash.fetch(:backoff_base_seconds).to_i.clamp(1, 86_400),
        backoff_max: hash.fetch(:backoff_max_seconds).to_i.clamp(1, 86_400),
        max_lateness: hash.fetch(:max_lateness_seconds).to_i.clamp(0, 7 * 86_400),
        lease: hash.fetch(:lease_seconds).to_i.clamp(30, 3600),
        batch_size: hash.fetch(:batch_size).to_i.clamp(1, 500),
        retention_days: hash.fetch(:retention_days).to_i.clamp(1, 3650),
        templates: hash.fetch(:templates).to_h.transform_keys(&:to_s).freeze,
        event_max_lateness: hash.fetch(:event_max_lateness_seconds, 172_800).to_i.clamp(0, 30 * 86_400),
        labels: hash.fetch(:preference_labels, {}).to_h { |kind, label| [ kind.to_s, label.to_h.transform_keys(&:to_s).freeze ] }.freeze
      )
    end

    def self.minutes_of_day(value)
      match = Reminders::TIME_FORMAT.match(value.to_s) or raise ArgumentError, "notifications.yml: bad time #{value.inspect}"
      match[1].to_i * 60 + match[2].to_i
    end

    # Seconds to wait before attempt number `attempts + 1` (attempts already made so far, at least 1).
    def backoff_seconds(attempts)
      [ backoff_base * (2**([ attempts, 1 ].max - 1)), backoff_max ].min
    end

    def template(kind)
      templates.fetch(kind.to_s)
    end

    # { "title" => ..., "hint" => ... } for the preferences screen (falls back to the kind's own name).
    def label(kind)
      labels.fetch(kind.to_s) { { "title" => kind.to_s.humanize, "hint" => "" } }
    end
  end
end
