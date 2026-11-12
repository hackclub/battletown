module Admin
  # Staff removing a screenshot from a ship under review (flag `ship_screenshots`): the safety valve for an image that
  # should not be kept (someone's personal details, anything inappropriate). Removes the stored picture; the ship and its
  # decision are untouched. Staff cannot add or replace images. Never touches a draft (those are the teen's own).
  class ShipImagesController < BaseController
    before_action { require_feature!(:ship_screenshots) }

    def destroy
      ship = Ship.where.not(status: "draft").find(params[:ship_id])
      removed = ShipImage.where(ship_id: ship.id, position: params[:position]).delete_all
      redirect_to admin_ship_path(ship), notice: (removed.positive? ? "Screenshot removed." : "That screenshot was already gone."), status: :see_other
    end
  end
end
