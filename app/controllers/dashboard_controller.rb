# The signed-in home page. All the numbers and sentences come from Dashboard::Presenter; this only settles the user's
# finished days first (lazily, the same call `rake game:settle` makes for everyone) and hands the presenter to the view.
class DashboardController < ApplicationController
  before_action :require_login, :require_onboarded

  def show
    settle_finished_days
    @dashboard = Dashboard::Presenter.new(user: current_user)
  end

  private

  # A settle that fails (a lock timeout, a bad row) must never take the page down: the presenter reads the live hours
  # for any day that is not settled yet. Only the error class is logged, never a message that could carry user data.
  def settle_finished_days
    Game::Settle.call(current_user)
  rescue StandardError => error
    Rails.logger.error("dashboard settle failed error=#{error.class}")
  end
end
