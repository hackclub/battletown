# POST /plinko/drops: drops one ball and answers with JSON for the animation. The server decides the slot
# (Plinko::Drop); the browser only plays the route back. Behind the `plinko` flag; CSRF-protected like every write.
class PlinkoDropsController < ApplicationController
  before_action { require_feature!(:plinko) }
  before_action :require_player

  def create
    result = Plinko::Drop.call(user: current_user, idempotency_key: params[:idempotency_key])
    render json: payload(result), status: result.replayed ? :ok : :created
  rescue Plinko::Drop::NoBalls
    render json: { error: "no_balls", message: "No balls left. Every #{Plinko::Config.current.seconds_per_ball / 60} minutes of coding earns one." },
           status: :unprocessable_content
  rescue Plinko::Drop::InvalidKey
    render json: { error: "bad_key", message: "That drop could not be made. Reload the page and try again." }, status: :unprocessable_content
  end

  private

  # A JSON endpoint: no redirects.
  def require_player
    return head(:unauthorized) unless signed_in?

    head :forbidden unless current_user.onboarded?
  end

  def payload(result)
    balls = Plinko::Balls.for(current_user)
    standings = Plinko::Standings.new(current_user, player: PlinkoPlayer.find_by(user_id: current_user.id))
    rank = standings.rank
    {
      slot: result.drop.slot, points: result.drop.points, path: result.path, seed: result.drop.seed, replayed: result.replayed,
      balls: { available: balls.available, seconds_to_next: balls.seconds_to_next },
      totals: { today: standings.today_points, week: standings.week_points, all_time: standings.total_points },
      rank: rank && { position: rank.position, players: rank.players }
    }
  end
end
