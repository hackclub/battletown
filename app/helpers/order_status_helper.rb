# Words for the six order statuses, in plain language, for the buyer's pages and for staff. The status is always written out; the
# colour and the mark in front of it (shop.css) only back the word up. A hold is staff-only: the buyer's helpers read the order's
# `buyer_status`, which turns on_hold into requested, so nothing here can leak it.
module OrderStatusHelper
  STAFF_STATUS_TEXT = { "requested" => "Requested", "on_hold" => "On hold", "shipped" => "Shipped", "fulfilled" => "Fulfilled",
                        "cancelled" => "Cancelled", "refunded" => "Refunded" }.freeze
  ORDER_STATUS_BADGES = { "requested" => "badge--warning", "on_hold" => "badge--warning", "shipped" => "badge--info", "fulfilled" => "badge--success",
                          "cancelled" => "badge--muted", "refunded" => "badge--muted" }.freeze

  # What each status means to the buyer. Placeholder copy: the project owner will edit this.
  BUYER_EXPLANATIONS = {
    "requested" => "The team has your order and will get to it soon.",
    "shipped" => "Your order is on its way.",
    "fulfilled" => "Your order was handed over. Enjoy it!",
    "cancelled" => "This order was cancelled.",
    "refunded" => "This order was refunded."
  }.freeze

  # The word the buyer sees (a hold reads as Requested).
  def order_status_text(order) = STAFF_STATUS_TEXT.fetch(order.buyer_status)

  def order_status_badge(order) = ORDER_STATUS_BADGES.fetch(order.buyer_status)

  # The CSS modifier for the mark in front of the word (never reveals a hold either).
  def order_status_class(order) = "shop-status--#{order.buyer_status}"

  def staff_order_status_text(order) = STAFF_STATUS_TEXT.fetch(order.status)

  # One or two plain sentences under the status chip on the buyer's own order page.
  def order_status_explanation(order)
    text = BUYER_EXPLANATIONS.fetch(order.buyer_status)
    text += " Your #{coins_text(order.coins)} are back." if order.coins.positive? && order.buyer_status.in?(%w[cancelled refunded])
    text
  end

  # "today", "1 day", "3 days": whole days since the order was placed.
  def order_age_text(order, now = Time.current)
    days = order.age_days(now)
    days.zero? ? "today" : pluralize(days, "day")
  end

  # The word for a line of the buyer's timeline (only the plain status changes ever reach it).
  def order_event_text(event)
    { "shipped" => "Shipped", "fulfilled" => "Fulfilled", "cancelled" => "Cancelled", "refunded" => "Refunded" }.fetch(event.action)
  end
end
