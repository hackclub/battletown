module Notifications
  # Email, the second channel of the notification outbox (docs/CONTRACT.md, "Email notifications"). Everything here is
  # behind the Flipper flag `email` (Features): with it off nothing is queued, rendered or sent.
  #
  # Only the kinds worth an email go out by email. The daily reminder, link questions and ship reminders stay Slack-only
  # (too frequent, or too small, for an inbox). A kind is on the list only while the Slack side knows it: the
  # `returning_nudge` entry becomes live the day that kind exists in Notification::KINDS.
  #
  #   ship_approved / ship_rejected  the decision on a ship ("ship decision"); transactional
  #   returning_nudge                "welcome back", queued alongside the Slack nudge (Email::Triggers)
  module Email
    KINDS = (%w[ship_approved ship_rejected returning_nudge] & Notification::KINDS).freeze
    # Kinds that start from a Slack notification row being created, not from a game event of their own.
    FOLLOWS_SLACK_ROW = %w[returning_nudge].freeze
    CHANNEL = "email".freeze

    Result = Slack::Result

    # Address checks for the recipient: present, a single plain address (the regexp is anchored, so no line break or list), and the shape Hack Club Auth gives us.
    def self.valid_address?(address)
      address.is_a?(String) && address.length <= 254 && address.match?(URI::MailTo::EMAIL_REGEXP)
    end

    def self.enabled? = Features.enabled?(:email)
  end
end
