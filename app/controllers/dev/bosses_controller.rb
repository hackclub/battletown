# Development-only: see the boss card for the signed-in dev user. With no parameters it is the real presenter reading
# the real rows (add time on /dev/hours and watch it move); `?state=in_progress|defeated|escaped|none` (and
# `&percent=<health left, 0 to 100>`) renders a made-up boss instead, so every state can be looked at without waiting
# for a week to pass. Outside development every request is a 404 (same as an unknown path); signed-out visitors are
# sent to sign in. Never reachable in test or production.
module Dev
  class BossesController < ApplicationController
    STATES = %w[in_progress defeated escaped none].freeze

    before_action :require_development!
    before_action :require_login

    def show
      @states = STATES
      @state = params[:state].to_s.presence_in(STATES)
      @percent = Integer(params[:percent].to_s, 10, exception: false)&.clamp(0, 100) || 62
      @presenter = if @state
        Bosses::Presenter.preview(state: @state, health_percent: @percent, today: Hours::Days.today(current_user))
      else
        Bosses::Presenter.new(user: current_user)
      end
    end

    private

    def require_development!
      raise ActionController::RoutingError, "Not Found" unless Rails.env.development?
    end
  end
end
