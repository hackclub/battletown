module ShipsHelper
  STATUS_LABELS = { "draft" => "Draft", "submitted" => "Waiting for review", "approved" => "Approved", "rejected" => "Needs changes",
                    "withdrawn" => "Withdrawn" }.freeze

  FIELD_LABELS = { description: "Description", repo_url: "GitHub link", demo_url: "Demo link", base: "" }.freeze

  # "GitHub link should look like ..." sentences with the labels people see on the form.
  def ship_error_messages(ship)
    ship.errors.map do |error|
      label = FIELD_LABELS.fetch(error.attribute, error.attribute.to_s.humanize)
      label.empty? ? error.message : "#{label} #{error.message}"
    end
  end

  # "1.5 hours", "1 hour", "0.25 hours".
  def ship_hours(seconds)
    number = number_with_precision(seconds / 3600.0, precision: 2, strip_insignificant_zeros: true)
    "#{number} #{number == '1' ? 'hour' : 'hours'}"
  end

  def ship_status_label(ship) = STATUS_LABELS.fetch(ship.status)

  # Badge colour classes per status; the label is always the words, never colour alone.
  STATUS_BADGES = { "draft" => "badge--muted", "submitted" => "badge--info", "approved" => "badge--success",
                    "rejected" => "badge--danger", "withdrawn" => "badge--muted" }.freeze

  def ship_status_badge(ship)
    tag.span(ship_status_label(ship), class: "badge #{STATUS_BADGES.fetch(ship.status)} ship-status ship-status--#{ship.status}")
  end

  # "Nov 3 to Nov 9" (or just "Nov 3" for one day).
  def ship_dates_text(first, last)
    return "" unless first && last

    first == last ? first.strftime("%b %-d") : "#{first.strftime('%b %-d')} to #{last.strftime('%b %-d')}"
  end

  # The owner's local date a ship was submitted on ("Nov 11" or "Nov 11, 2026"), so it lines up with the local dates in
  # the ship's window instead of the UTC date.
  def ship_submitted_on(ship, year: false)
    return unless ship.submitted_at

    date = Game::Days.local_date(ship.submitted_at, ship.user.time_zone)
    date.strftime(year ? "%b %-d, %Y" : "%b %-d")
  end

  # Coins an hour at the deflated rate, for the "past 6 hours" note on the form.
  def ship_deflated_rate(config = Game::Config.current)
    format("%g", config.coins_per_hour * config.deflation_multiplier_milli / 1000.0)
  end

  # The same Hack Club Auth verify link the onboarding account step uses.
  def ship_verify_link
    link_to "Verify with Hack Club", "https://auth.hackclub.com", target: "_blank", rel: "noopener noreferrer"
  end
end
