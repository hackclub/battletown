module Notifications
  # Per-person switches for each kind of Slack message. Every kind is on until the person turns it off. Asked before
  # an outbox row is created and again by the dispatcher just before sending, so someone who opts out after a
  # message was queued gets nothing. An unknown kind is never enabled.
  module Preferences
    module_function

    def kinds = Notification::KINDS

    def enabled?(user, kind)
      return false unless user && kinds.include?(kind.to_s)

      NotificationPreference.where(user_id: user.id, kind: kind.to_s, enabled: false).none?
    end

    # { "daily_reminder" => true, ... } for every kind, defaults filled in.
    def settings(user)
      off = NotificationPreference.where(user_id: user.id, enabled: false).pluck(:kind)
      kinds.index_with { |kind| off.exclude?(kind) }
    end

    # `choices` is { kind => true/false/"1"/"0" }. Unknown kinds and values that are not a clear yes or no are ignored.
    # Returns true when at least one switch changed.
    def update!(user, choices)
      rows = choices.to_h.filter_map do |kind, value|
        enabled = cast(value)
        { user_id: user.id, kind: kind.to_s, enabled: enabled } if kinds.include?(kind.to_s) && !enabled.nil?
      end
      return false if rows.empty?

      before = settings(user)
      NotificationPreference.upsert_all(rows, unique_by: %i[user_id kind])
      settings(user) != before
    end

    def cast(value)
      case value.to_s
      when "1", "true" then true
      when "0", "false" then false
      end
    end
    private_class_method :cast
  end
end
