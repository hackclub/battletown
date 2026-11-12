module ShopHelper
  VERIFY_URL = "https://auth.hackclub.com".freeze

  STATUS_TEXT = { "requested" => "Requested", "fulfilled" => "Fulfilled", "cancelled" => "Cancelled" }.freeze

  # "1 coin", "30 coins", "1,200 coins".
  def coins_text(amount) = "#{number_with_delimiter(amount)} #{amount == 1 ? 'coin' : 'coins'}"

  # A price: "Free" for zero.
  def price_text(amount) = amount.zero? ? "Free" : coins_text(amount)

  def order_status_text(order) = STATUS_TEXT.fetch(order.status)

  # Orders carry a calendar date in the person's own zone (UTC when unset).
  def order_date(time, user = current_user)
    zone = ActiveSupport::TimeZone[user.time_zone.to_s] || ActiveSupport::TimeZone["UTC"]
    time.in_time_zone(zone).strftime("%-d %b %Y")
  end

  def verification_label(user) = user.verification_status.tr("_", " ")
end
