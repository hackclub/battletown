# The live boss stage's data (GET /boss/fighters, signed in and onboarded; boss_fighters_controller.js polls it): who is fighting the
# boss in the last 24 hours, and the numbers and sentences the stage redraws (Bosses::Presenter#live_payload). Public bits only, see
# Bosses::Fighters. Per person (the viewer's own circle and total are in it), so it is private and revalidated by ETag (Rails's default
# "max-age=0, private, must-revalidate"): an unchanged stage is a bodyless 304. Rack::Attack limits it per signed-in person (config/initializers/rack_attack.rb).
class BossFightersController < ApplicationController
  before_action :require_login, :require_onboarded

  def show
    payload = Bosses::Presenter.new(user: current_user, today: Hours::Days.today("UTC")).live_payload
    render json: payload if stale?(etag: payload.to_json, public: false)
  end
end
