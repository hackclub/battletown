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

  REVIEW_BADGES = { "unreviewed" => [ "Unreviewed", "badge--muted" ], "ok" => [ "Reviewed OK", "badge--success" ],
                    "flagged" => [ "Flagged", "badge--danger" ] }.freeze

  # A project's review state as words on a pill (never colour alone).
  def admin_review_badge(project)
    text, variant = REVIEW_BADGES.fetch(project.review_status)
    admin_badge(text, variant)
  end

  # A link out to something a teen typed (their repo or demo). Plain text link, https only, never embedded; nil for anything
  # else (a javascript: or http: value, though the database already refuses those).
  def admin_external_link(url)
    return unless url.to_s.match?(%r{\Ahttps://[^\s]+\z})

    link_to url.to_s.delete_prefix("https://"), url.to_s, rel: "noopener noreferrer nofollow", target: "_blank"
  end

  # The owner's display name only (never email or ids), linked to the staff user page when that page exists.
  def admin_owner_name(user)
    name = user.display_name.presence || "No name"
    respond_to?(:admin_user_path) ? link_to(name, admin_user_path(user)) : name
  end

  SHIP_COUNT_LABELS = { "submitted" => "waiting", "approved" => "approved", "rejected" => "rejected", "withdrawn" => "withdrawn" }.freeze

  # "2 ships (1 waiting, 1 approved)" from { "submitted" => 1, "approved" => 1 }; "None" when empty.
  def admin_ship_counts_text(counts)
    return "None" if counts.blank?

    parts = SHIP_COUNT_LABELS.filter_map { |status, label| "#{counts[status]} #{label}" if counts[status].to_i.positive? }
    "#{pluralize(counts.values.sum, 'ship')} (#{parts.join(', ')})"
  end

  # The queue's own URL with some filters changed; only the whitelisted filters ever reach a link.
  def admin_projects_filter_path(filters, **changes)
    admin_projects_path(filters.merge(changes).compact_blank)
  end

  # "5 hours" for a price in coins (10 coins is an hour of approved coding, from config/game.yml).
  def shop_hours_text(coins) = Prize.hours_text_for(coins.to_i)

  # The question asked before archiving an item; says how many people have it picked.
  def shop_archive_confirm(name, picks)
    sentence = "Archive #{name}? It will disappear from the shop, the landing page and the prize picker."
    sentence += " #{picks} #{picks == 1 ? 'person is' : 'people are'} working toward it: their pick and any orders already made keep working." if picks.positive?
    sentence
  end
end
