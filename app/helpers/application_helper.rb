module ApplicationHelper
  TITLE_BRAND = "BattleTown".freeze

  # The <title> for the layout: "<Page> - BattleTown" when the view set one with `content_for :title, "<Page>"`, for
  # everyone (every page needs a title that says what it is, so the visitor steps of onboarding get theirs too). With no
  # page name, signed-out visitors get the bare brand (the landing page) and signed-in users "Home - BattleTown". Views
  # pass only the page name; the brand is added here.
  def page_title
    # content_for escapes what it is given and the layout escapes the whole title again, so "You're in!" would show
    # as "You&#39;re in!" in the tab: unescape once here and let the layout do the one escape.
    page = content_for(:title).presence
    return TITLE_BRAND if page.nil? && !signed_in?

    "#{page ? CGI.unescapeHTML(page.to_s) : 'Home'} - #{TITLE_BRAND}"
  end

  # The one arrow icon, drawn as on the landing page's call to action (a bold chevron on a 41.778 x 42 box, the shape centered in it).
  # Every arrow inside a button uses it; `css_class` sets the size rule that applies to it (cta__arrow, btn__arrow).
  def arrow_icon(css_class)
    tag.svg(tag.path(d: "M4 21H37.778M20.778 38L37.778 21L20.778 4", fill: "none", stroke: "currentColor", "stroke-width": 8, "stroke-linecap": "round", "stroke-linejoin": "round"),
            class: css_class, viewBox: "0 0 41.778 42", "aria-hidden": "true", focusable: "false")
  end

  # A header link that says which page you are on: aria-current="page" on the current section, so screen readers and
  # the stylesheet agree. `section` is the path prefix that counts as "this page" (the link's own path by default).
  def nav_link(label, path, section: path)
    current = request.path == section || request.path.start_with?("#{section}/")
    link_to label, path, class: ("is-current" if current), "aria-current": ("page" if current)
  end

  # True while one of the pages in the Settings menu is open.
  def settings_menu_current?
    [ hackatime_path, settings_notifications_path ].any? { |path| request.path == path || request.path.start_with?("#{path}/") }
  end
end
