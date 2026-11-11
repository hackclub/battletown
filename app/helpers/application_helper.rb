module ApplicationHelper
  TITLE_BRAND = "BattleTown".freeze

  # The <title> for the layout. Signed-out visitors always get the bare brand. Signed-in users get
  # "<Page> - BattleTown" when the view set one with `content_for :title, "<Page>"`, otherwise
  # "Home - BattleTown". Views pass only the page name; the brand is added here.
  def page_title
    return TITLE_BRAND unless signed_in?

    "#{content_for(:title).presence || 'Home'} - #{TITLE_BRAND}"
  end
end
