# The Plinko page (behind the `plinko` flag; docs/CONTRACT.md, "Plinko"): the board, the player's balls and points, and
# the opt-in weekly leaderboard. Dropping a ball is PlinkoDropsController. Nothing here touches coins.
class PlinkoController < ApplicationController
  before_action { require_feature!(:plinko) }
  before_action :require_login, :require_onboarded

  def show
    @board = Plinko::Board.current
    @player = Plinko::Players.for(current_user)
    @balls = Plinko::Balls.for(current_user)
    @standings = Plinko::Standings.new(current_user, player: @player)
    @config = Plinko::Config.current
  end

  # "Show me on the leaderboard": off until the player turns it on, and they can turn it off again at any time.
  def leaderboard
    on = ActiveModel::Type::Boolean.new.cast(params[:leaderboard_opt_in]) == true
    Plinko::Players.opt_in!(current_user, on)
    redirect_to plinko_path, notice: on ? "You are on the weekly leaderboard." : "You are off the leaderboard."
  end

  def nickname
    player = Plinko::Players.regenerate!(current_user)
    redirect_to plinko_path, notice: "Your nickname is now #{player.nickname}."
  end
end
