# Serves one ship screenshot (flag `ship_screenshots`; with it off the route does not exist and this answers 404 too).
# Only the ship's owner and staff can see it: everyone else, signed out included, gets the plain 404 an unknown path
# gets (nothing says that a picture exists). Staff see the same ships the review queue lists, so a draft stays private to
# its owner. The image is never cached, never sniffed into another type and never allowed to run anything.
class ShipImagesController < ApplicationController
  before_action { require_feature!(:ship_screenshots) }
  before_action :set_ship

  def show
    image = ShipImage.find_by!(ship_id: @ship.id, position: params[:position])
    response.headers["Cache-Control"] = "private, no-store"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Content-Security-Policy"] = "sandbox"
    send_data image.content, type: ShipImage::CONTENT_TYPE, disposition: "inline"
  end

  private

  def not_found = raise(ActionController::RoutingError, "Not Found")

  def set_ship
    not_found unless signed_in?
    @ship = Ship.find_by(id: params[:ship_id])
    not_found unless @ship && (@ship.user_id == current_user.id || (current_user.admin? && !@ship.status_draft?))
  end
end
