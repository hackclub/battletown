# The free signup sticker: a confirmation page (with the address step when the sticker is posted) and the claim itself (one per
# person, no coins, allowed before identity is verified). Same address flow as any physical order, with the draft key "sticker".
class StickerClaimsController < ApplicationController
  before_action :require_login, :require_onboarded
  before_action :no_store

  def new
    @sticker = Prize.free_signup
    return redirect_to(shop_path, alert: Shop::ItemUnavailable.new.message) unless @sticker
    return redirect_to(orders_path, notice: "You already claimed your sticker.") if current_user.orders.exists?(kind: "signup_sticker")

    @address_offer = AddressOffer.live_for(current_user, "sticker") if @sticker.requires_shipping?
    @address_offer_expired = @sticker.requires_shipping? && @address_offer.nil? && AddressOffer.expired_for?(current_user, "sticker")
    @lookup = { purpose: "sticker", item: @sticker.key, draft: "sticker" }
  end

  def create
    needs_address = Prize.free_signup&.requires_shipping? == true
    Shop::ClaimSticker.call(user: current_user, address_id: text_param(:address_id), address_required: needs_address)
    notice = needs_address ? "Sticker claimed. We'll post it to the address you picked." : "Sticker claimed. The team will message you on Slack to arrange delivery."
    redirect_to orders_path, notice: notice
  rescue Orders::AddressError => error
    redirect_to new_shop_sticker_path, alert: error.message
  rescue Shop::Error => error
    redirect_to shop_path, alert: error.message
  end

  private

  def no_store
    response.headers["Cache-Control"] = "no-store"
  end

  # Only plain strings are accepted (a nested or array param becomes "").
  def text_param(name) = params[name].is_a?(String) ? params[name] : ""
end
