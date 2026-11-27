# Every icon in the app comes from here. Text characters are NOT allowed as icons (no "‹", "✓", "→", "×", "+", "▾" or
# emoji used as a control, and no `content: "✓"` in CSS): a character's ink is never centered in its line box, so it
# sits off-center in its button, and no CSS fix holds across fonts and sizes.
#
# The convention, enforced by test/integration/icon_glyphs_test.rb (static) and test/system/icon_centering_test.rb
# (measures the drawn pixels in a real browser):
#
#   * Draw the icon with `icon(:name)`. Each drawing below is symmetric about the center (12, 12) of a 24 x 24 viewBox,
#     so its geometry is centered by construction. Add a new one the same way (its bounding box must be centered).
#   * Put the icon inside a container marked `data-icon-box`: the button, circle, chip or badge it must be centered in.
#     The icon is centered on both axes in that box. Add `data-icon-axis="y"` when the icon sits beside a label (a badge
#     mark, an arrow after a button's text): then only the vertical center is checked.
#   * The box centers with `display: grid; place-items: center` (or inline-flex with align-items: center).
module IconHelper
  # name => [paint, svg markup]. paint :stroke draws a 2-unit round line in currentColor; :fill fills with currentColor.
  ICONS = {
    chevron_left: [ :stroke, '<path d="M14.5 5.5 9.5 12l5 6.5"/>' ],
    chevron_right: [ :stroke, '<path d="m9.5 5.5 5 6.5-5 6.5"/>' ],
    chevron_down: [ :stroke, '<path d="m6 9 6 6 6-6"/>' ],
    arrow_right: [ :stroke, '<path d="M4 12h16M14 6l6 6-6 6"/>' ],
    check: [ :stroke, '<path d="m5 12 5 5L19 7"/>' ],
    close: [ :stroke, '<path d="m6 6 12 12M18 6 6 18"/>' ],
    plus: [ :stroke, '<path d="M12 5v14M5 12h14"/>' ],
    minus: [ :stroke, '<path d="M5 12h14"/>' ],
    pause: [ :stroke, '<path d="M9 6v12M15 6v12"/>' ],
    exclaim: [ :stroke, '<path d="M12 5v9M12 19v.01"/>' ],
    ellipsis: [ :stroke, '<path d="M6 12v.01M12 12v.01M18 12v.01"/>' ],
    undo: [ :stroke, '<path d="M9 6.5 4 11.5l5 5M4 11.5h10c3.3 0 6 2.7 6 6"/>' ],
    dot: [ :fill, '<circle cx="12" cy="12" r="1.75"/>' ],
    triangle_right: [ :fill, '<path d="M8 6l8 6-8 6z"/>' ],
    triangle_down: [ :fill, '<path d="M6 8h12l-6 8z"/>' ]
  }.freeze

  # `icon(:check)` -> an inline <svg class="icon icon--check"> sized 1em, decorative (aria-hidden). Put the accessible
  # name on the control that holds it (aria-label or visually hidden text), never on the icon.
  def icon(name, **options)
    paint, body = ICONS.fetch(name.to_sym) { raise ArgumentError, "unknown icon #{name.inspect}; add it to IconHelper::ICONS" }
    attributes = paint == :stroke ? { fill: "none", stroke: "currentColor", "stroke-width": 2, "stroke-linecap": "round", "stroke-linejoin": "round" } : { fill: "currentColor" }
    tag.svg(body.html_safe, **attributes, viewBox: "0 0 24 24", class: class_names("icon", "icon--#{name.to_s.dasherize}", options.delete(:class)),
            "aria-hidden": "true", focusable: "false", **options)
  end
end
