module Notifications
  # Per-person switches for each kind of message, per channel (Slack DM or email). Every kind is on until the person
  # turns it off (nothing is stored for the default). Asked before an outbox row is created and again by the
  # dispatcher just before sending, so someone who opts out after a message was queued gets nothing. An unknown kind,
  # or a kind the channel does not carry, is never enabled. For email the person's global "no email at all" switch
  # (`users.email_opted_out_at`, also set by the one-click unsubscribe) overrides every kind.
  module Preferences
    SLACK = "slack_dm".freeze
    EMAIL = "email".freeze

    # Kinds that belong to a feature flag: while the flag is off the switch is not shown on /settings/notifications.
    FEATURE_KINDS = { "returning_nudge" => :returning, "nps_prompt" => :nps }.freeze

    module_function

    # The kinds a channel carries: every kind on Slack, only the few worth an email on email.
    def kinds(channel: SLACK) = channel == EMAIL ? Email::KINDS : Notification::KINDS

    def enabled?(user, kind, channel: SLACK)
      return false unless user && kinds(channel: channel).include?(kind.to_s)
      return false if channel == EMAIL && user.email_opted_out?

      NotificationPreference.where(user_id: user.id, kind: kind.to_s, channel: channel, enabled: false).none?
    end

    # { "daily_reminder" => true, ... } for every kind of the channel, defaults filled in. This is the per-kind switch
    # only: for email the global switch is `user.email_opted_out?`.
    def settings(user, channel: SLACK)
      off = NotificationPreference.where(user_id: user.id, channel: channel, enabled: false).pluck(:kind)
      kinds(channel: channel).index_with { |kind| off.exclude?(kind) }
    end

    # The kinds a person may change right now: every kind of the channel except those whose feature is switched off.
    def visible_kinds(channel: SLACK)
      kinds(channel: channel).reject { |kind| FEATURE_KINDS.key?(kind) && !Features.enabled?(FEATURE_KINDS.fetch(kind)) }
    end

    # `settings` without the kinds whose feature is switched off (what /settings/notifications lists).
    def visible_settings(user)
      settings(user).reject { |kind, _| FEATURE_KINDS.key?(kind) && !Features.enabled?(FEATURE_KINDS.fetch(kind)) }
    end

    # `choices` is { kind => true/false/"1"/"0" }. Unknown kinds and values that are not a clear yes or no are ignored.
    # Returns true when at least one switch changed. (`channel` is positional so a brace-less hash of string keys still
    # reads as `choices`.)
    def update!(user, choices, channel = SLACK)
      allowed = kinds(channel: channel)
      rows = choices.to_h.filter_map do |kind, value|
        enabled = cast(value)
        { user_id: user.id, kind: kind.to_s, channel: channel, enabled: enabled } if allowed.include?(kind.to_s) && !enabled.nil?
      end
      return false if rows.empty?

      before = settings(user, channel: channel)
      NotificationPreference.upsert_all(rows, unique_by: %i[user_id kind channel])
      settings(user, channel: channel) != before
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
