# The reward track overview (flag `merch_track`): every week's item and the signed-in person's own status for each.
# Only their own numbers. The routes exist only while the flag is on; the before_action says the same for any other
# entry point. Settling the finished days first is the same lazy call the dashboard makes.
class MerchController < ApplicationController
  Row = Data.define(:week, :status)

  before_action :require_login, :require_onboarded
  before_action { require_feature!(:merch_track) }

  def index
    settle_finished_days
    config = MerchTrack::Config.current
    today = Hours::Days.today(current_user)
    claims = current_user.merch_claims.index_by(&:boss_id)
    @rows = MerchTrack::Track.weeks(config: config).map do |week|
      started = week.boss && week.boss.starts_on <= today
      Row.new(week: week, status: (MerchTrack::Status.for(current_user, week.boss, config: config, claim: claims[week.boss.id]) if started))
    end
    @required = config.days_required
    @requires_ship = config.claim_requires_ship
    @goal_minutes = Game::Config.current.goal_seconds / 60
  end

  private

  def settle_finished_days
    Game::Settle.call(current_user)
  rescue StandardError => error
    Rails.logger.error("merch settle failed error=#{error.class}")
  end
end
