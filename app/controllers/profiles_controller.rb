# Player profiles (projects/battletown/specs/contract.md "Player profiles"). Signed in and onboarded only. Every player has one and
# every signed-in, onboarded player can open any of them: there is no opt-in and no opt-out.
#
#   GET /players/:slug  a player's profile. An address nobody has and a malformed one are ONE plain 404, so addresses cannot be probed.
#                       Someone who is not signed in, or has not finished onboarding, never gets here (the same redirect as every
#                       other signed-in page, whatever the address).
#   GET /profile        my own profile: it goes to /players/:slug.
class ProfilesController < ApplicationController
  before_action :require_login, :require_onboarded
  before_action :no_store

  def show
    owner = User.by_slug(params[:slug])
    raise ActiveRecord::RecordNotFound unless owner

    track_event(:profile_viewed, own: owner.id == current_user.id)
    @profile = Profiles::Presenter.new(user: owner, viewer: current_user)
  end

  def mine
    redirect_to player_path(current_user.public_slug)
  end

  private

  def no_store
    response.headers["Cache-Control"] = "no-store"
  end
end
