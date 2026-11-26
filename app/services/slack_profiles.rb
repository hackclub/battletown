# Slack display name and picture for the players who have a Slack id (every player has a profile, so there is no opt-in; "Use my Slack
# name and picture" is ON until a player turns it off). Decisions: projects/battletown/runbooks/slack-app.md ("Profile data").
#
#   SlackProfiles.refresh_later(user)   # cheap, never raises: queues a background fetch when one is due
#   SlackProfiles::Refresh.call(user)   # the fetch itself (the job and `rake slack:refresh_profiles` call it)
#
# Rules that hold everywhere here: only people with a Slack id who have not turned "Use my Slack name and picture" off are ever fetched
# (never a simulated player: they have no Slack id); the fetch is lazy (a page or sign-in asks, a background
# job does it, nothing waits), at most once per REFRESH_EVERY per person, spread under Slack's `users.info` limit (SlackProfiles::Gate), and
# any failure leaves the generated avatar and the profile name exactly as they were. Nothing from Slack is stored except the sanitised
# display name and a re-encoded small picture served by this app (SlackProfiles::Avatar, PlayerAvatarsController).
module SlackProfiles
  REFRESH_EVERY = 24.hours

  module_function

  # Whether this person is a candidate for a fetch at all (has a Slack id and the bot token is set). Does not look at the choice
  # or at when the last fetch was.
  def eligible?(user)
    user.slack_id.to_s.match?(Client::SLACK_ID_FORMAT) && token?
  end

  def token? = ENV["SLACK_BOT_TOKEN"].present?

  # The choice "Use my Slack name and picture" is ON until the person turns it off: no row means on (the first fetch makes the row).
  def use_name?(profile) = profile.nil? || profile.use_name
  def use_picture?(profile) = profile.nil? || profile.use_picture

  # Queues the background fetch when one is due, after the current transaction commits. Cheap (one small query, no HTTP), never
  # raises into a page, a sign-in or a ship, and does nothing for someone who is not eligible, switched it off, or was fetched today.
  def refresh_later(user)
    return unless user && eligible?(user)

    profile = SlackProfile.for(user)
    return if profile && !((profile.use_name || profile.use_picture) && profile.due?)

    ActiveRecord.after_all_transactions_commit { SlackProfileJob.perform_later(user.id) }
    nil
  rescue StandardError => error
    Rails.logger.warn("SlackProfiles: could not queue a refresh (#{error.class})")
    nil
  end

  # Every person with a Slack id who is due, oldest first (for the rake task that fills everybody in after the token is first set).
  def due_scope(now = Time.current)
    User.where.not(slack_id: [ nil, "" ])
        .joins("LEFT JOIN slack_profiles ON slack_profiles.user_id = users.id")
        .where("slack_profiles.id IS NULL OR ((slack_profiles.use_name OR slack_profiles.use_picture) AND " \
               "(slack_profiles.next_attempt_at IS NULL OR slack_profiles.next_attempt_at <= :now) AND " \
               "(slack_profiles.fetched_at IS NULL OR slack_profiles.fetched_at <= :cutoff))", now: now, cutoff: now - REFRESH_EVERY)
        .order(Arel.sql("slack_profiles.fetched_at ASC NULLS FIRST, users.id"))
  end
end
