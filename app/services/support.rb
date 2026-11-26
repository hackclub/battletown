# Where a person can reach the Battletown team, read from config.x.support (config/application.rb: SUPPORT_EMAIL and
# SUPPORT_SLACK_CHANNEL). Used by the "who to ask" lines: the order page, the not-eligible note and the eligibility help_line in
# config/game.yml (its {support} is where_to_ask). Nothing here is ever invented: with neither set the wording is "the Battletown
# channel in the Hack Club Slack" and there is no email. Values are read when asked (not memoised), so a change of configuration
# shows at once. A value that does not look like an email address or a Slack channel name is ignored rather than shown.
module Support
  FALLBACK_CHANNEL = "the Battletown channel in the Hack Club Slack".freeze
  EMAIL_FORMAT = /\A[^@\s<>"',;]{1,64}@[A-Za-z0-9.-]{1,190}\.[A-Za-z]{2,}\z/
  CHANNEL_FORMAT = /\A[a-z0-9][a-z0-9_-]{0,79}\z/

  module_function

  # The support email address, or nil when none is configured (or it is malformed).
  def email
    value = config.email.to_s.strip
    value if value.match?(EMAIL_FORMAT)
  end

  # The Slack channel name without the "#" (for example "battletown"), or nil.
  def channel_name
    value = config.slack_channel.to_s.strip.delete_prefix("#").downcase
    value if value.match?(CHANNEL_FORMAT)
  end

  # "the #battletown channel in the Hack Club Slack", or the fallback wording when no channel is configured.
  def channel_text = channel_name ? "the ##{channel_name} channel in the Hack Club Slack" : FALLBACK_CHANNEL

  # The channel text, plus the email when there is one: "the Battletown channel in the Hack Club Slack, or email help@example.org".
  # Reads after "ask in ", "reach out in " and "message us in ".
  def where_to_ask = email ? "#{channel_text}, or email #{email}" : channel_text

  def config = Rails.configuration.x.support
end
