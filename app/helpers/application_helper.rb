module ApplicationHelper
  TITLE_BRAND = "BattleTown".freeze

  # The <title> for the layout. Signed-out visitors always get the bare brand. Signed-in users get
  # "<Page> - BattleTown" when the view set one with `content_for :title, "<Page>"`, otherwise
  # "Home - BattleTown". Views pass only the page name; the brand is added here.
  def page_title
    return TITLE_BRAND unless signed_in?

    "#{content_for(:title).presence || 'Home'} - #{TITLE_BRAND}"
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
