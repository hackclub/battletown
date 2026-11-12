# Serves a shop item's picture (the re-encoded WebP kept in shop_items; see ShopItem). Public on purpose: the landing page
# shows the shop's items to signed-out visitors. An item staff have archived is not on show any more, so its picture is
# served to staff only (everyone else gets the plain 404 an unknown path gets). The picture is the same for everyone, so
# it is cached by the browser for a day (private: no shared cache keeps it), revalidated by ETag (the SHA-256 of the
# bytes), never sniffed into another type and never allowed to run anything. The URLs the pages use carry `?v=<hash prefix>`,
# so a replaced picture is fetched fresh at once.
class ShopItemImagesController < ApplicationController
  def show
    item = ShopItem.without_content.find_by(key: params[:key])
    raise ActionController::RoutingError, "Not Found" unless item&.image? && (item.active || (signed_in? && current_user.admin?))

    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Content-Security-Policy"] = "sandbox"
    expires_in 1.day, public: false
    return unless stale?(etag: item.image_sha256, public: false)

    send_data ShopItem.image_content_for(item.key), type: ShopItem::CONTENT_TYPE, disposition: "inline"
  end
end
