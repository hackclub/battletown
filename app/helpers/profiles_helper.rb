module ProfilesHelper
  # The generated avatar: the person's initial on one of a dozen colours chosen from their opaque address. Nothing is fetched from
  # anywhere (no Slack or Hack Club picture), and a screen reader skips it (the name is right beside it). `size` is :md or :lg.
  # With `url` (this app's own copy of their Slack picture, SlackProfiles) the picture fills the circle instead of the initial.
  def profile_avatar(initial, tone, size: :md, url: nil)
    content = url ? image_tag(url, alt: "", class: "avatar__img", loading: "lazy", decoding: "async", width: 128, height: 128, draggable: "false") : initial
    tag.span(content, class: "avatar avatar--tone-#{tone.to_i % Profiles::Presenter::TONES} avatar--#{size}", "aria-hidden": "true")
  end

  # The words and colour for a ship's status (ShipsHelper's labels), by status name: the label is always the words, never colour alone.
  def profile_ship_status(status)
    tag.span(ShipsHelper::STATUS_LABELS.fetch(status), class: "badge #{ShipsHelper::STATUS_BADGES.fetch(status)} ship-status ship-status--#{status}")
  end

  # A link to a project's repo or demo. Only https becomes a link (the presenter checked once, this checks again). It opens in the
  # same tab, with no referrer and no opener.
  def profile_external_link(label, url)
    return unless url.to_s.start_with?("https://")

    link_to label, url.to_s, rel: "noopener noreferrer"
  end

  # "1 ship", "3 ships", "No ships yet".
  def profile_ships_text(count) = count.zero? ? "No ships yet" : pluralize(count, "ship")
end
