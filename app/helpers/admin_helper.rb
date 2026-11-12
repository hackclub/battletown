# Small markup helpers for the admin pages (app/views/admin), so every table and status looks the same.
module AdminHelper
  ORDER_BADGES = { "requested" => "badge--warning", "fulfilled" => "badge--success", "cancelled" => "badge--muted" }.freeze

  # A table that scrolls sideways inside its own box on a phone instead of the page. The wrapper is focusable and named so
  # keyboard users can scroll it (axe: scrollable-region-focusable).
  def table_region(label, &block)
    tag.div(class: "table-wrap", tabindex: 0, role: "region", "aria-label": label, &block)
  end

  # A status shown as words on a coloured pill, never colour alone.
  def admin_badge(text, variant = nil)
    tag.span(text, class: class_names("badge", variant))
  end

  def admin_ship_badge(ship)
    return admin_badge("Waiting", "badge--warning") if ship.status_submitted?

    admin_badge(ship.status.humanize, ShipsHelper::STATUS_BADGES.fetch(ship.status))
  end

  def admin_order_badge(order, text)
    admin_badge(text, ORDER_BADGES.fetch(order.status))
  end
end
