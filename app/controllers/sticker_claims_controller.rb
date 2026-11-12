# Claims the free signup sticker (one per person, no coins, allowed before identity is verified).
class StickerClaimsController < ApplicationController
  before_action :require_login, :require_onboarded

  def create
    Shop::ClaimSticker.call(user: current_user)
    redirect_to orders_path, notice: "Sticker claimed. The team will message you on Slack to arrange delivery."
  rescue Shop::Error => error
    redirect_to shop_path, alert: error.message
  end
end
