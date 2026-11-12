module Notifications
  module Email
    # Typed view of the `email:` section of config/notifications.yml: subject lines, the weekly cap and the labels of
    # the email switches. The sender address is not here, it is the MAIL_FROM environment variable (EmailTransport).
    Config = Data.define(:subjects, :max_per_week, :capped_kinds, :labels) do
      PLACEHOLDER = /\{(\w+)\}/

      def self.current
        @current ||= from_hash(Rails.application.config_for(:notifications).fetch(:email))
      end

      def self.reset!
        @current = nil
      end

      def self.from_hash(hash)
        new(
          subjects: hash.fetch(:subjects).to_h.transform_keys(&:to_s).freeze,
          max_per_week: hash.fetch(:max_per_week).to_i.clamp(0, 50),
          capped_kinds: Array(hash.fetch(:capped_kinds, [])).map(&:to_s).freeze,
          labels: hash.fetch(:preference_labels, {}).to_h { |kind, label| [ kind.to_s, label.to_h.transform_keys(&:to_s).freeze ] }.freeze
        )
      end

      # The subject line for a kind. Values are one line (the mailer's values are already shortened and squished) and a
      # line break can never get into a header.
      def subject(kind, values)
        subjects.fetch(kind.to_s).gsub(PLACEHOLDER) { values.fetch(Regexp.last_match(1).to_sym, "").to_s }.squish
      end

      def label(kind)
        labels.fetch(kind.to_s) { { "title" => kind.to_s.humanize, "hint" => "" } }
      end

      def capped?(kind) = capped_kinds.include?(kind.to_s)
    end
  end
end
