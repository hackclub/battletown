# Markup helpers for the weekly merch track (app/views/merch, app/views/dashboard/_merch). Every state is said in words;
# the dot glyphs and colours are decoration on top of that.
module MerchHelper
  # The glyph inside a day's dot: a different shape per state, so the dots read without colour.
  DAY_MARKS = { met: "✓", missed: "–", pending: "…", future: "", not_counted: "·" }.freeze

  # The screen-reader (and tooltip-free) text for one day.
  DAY_TEXT = {
    met: "goal met",
    missed: "goal not met",
    pending: "still counting, it settles once the day has closed",
    future: "still to come",
    not_counted: "before you signed up, so it does not count"
  }.freeze

  STATE_BADGES = {
    claimed: [ "Claimed", "badge--warning" ],
    fulfilled: [ "Fulfilled", "badge--success" ],
    cancelled: [ "Cancelled", "badge--muted" ],
    claimable: [ "Ready to claim", "badge--success" ],
    needs_verification: [ "Locked for now", "badge--warning" ],
    needs_ship: [ "Locked for now", "badge--warning" ],
    in_progress: [ "In progress", "badge--info" ],
    fresh_start: [ "Fresh start next week", "badge--muted" ]
  }.freeze

  def merch_day_mark(day) = DAY_MARKS.fetch(day.state)

  # "Friday 13 November: goal met" (plus "today" on today's dot).
  def merch_day_text(day)
    "#{day.date.strftime('%A %-d %B')}#{' (today)' if day.today}: #{DAY_TEXT.fetch(day.state)}"
  end

  def merch_state_badge(status)
    text, variant = STATE_BADGES.fetch(status.state)
    tag.span(text, class: class_names("badge", variant))
  end

  # "13 Nov to 19 Nov"
  def merch_week_range(boss) = "#{boss.starts_on.strftime('%-d %b')} to #{boss.ends_on.strftime('%-d %b')}"
end
