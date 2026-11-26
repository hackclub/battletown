# Fetches one player's Slack name and picture in the background (SlackProfiles::Refresh), so no page or sign-in ever waits
# for Slack. Production runs Active Job on the in-process :async adapter (config/environments/production.rb): this runs in that
# process's thread pool, and a job lost to a restart is simply asked for again by the next sign-in or dashboard visit (SlackProfiles.refresh_later),
# because the person's row says when the next fetch is due. A Solid Queue worker, when there is one, runs it the same way.
#
# It never raises: Refresh already turns every failure into a state on the person's row. When Slack says to wait (or a network problem
# is worth another try) the job puts itself back after that long, at most MAX_ATTEMPTS times in a row.
class SlackProfileJob < ApplicationJob
  queue_as :default

  MAX_ATTEMPTS = 4

  def perform(user_id, attempt = 1)
    user = User.find_by(id: user_id)
    return unless user

    outcome = SlackProfiles::Refresh.call(user)
    return unless outcome.retry_in && attempt < MAX_ATTEMPTS

    self.class.set(wait: outcome.retry_in.seconds).perform_later(user.id, attempt + 1)
  rescue StandardError => error
    Rails.logger.warn("SlackProfileJob failed (#{error.class})")
  end
end
