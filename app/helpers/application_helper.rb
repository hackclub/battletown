module ApplicationHelper
  TITLE_BRAND = "Battletown".freeze

  DEFAULT_META_DESCRIPTION = "Battletown is a Hack Club program for teens aged 13 to 18. Build projects, take down a weekly boss with the community and earn prizes.".freeze

  def default_meta_description = DEFAULT_META_DESCRIPTION

  # An absolute URL on the app's public address (APP_URL), for link previews, which must not be relative.
  def public_url(path) = "#{Notifications::Links.base}#{path}"

  # The <title> for the layout: "<Page> - Battletown" when the view set one with `content_for :title, "<Page>"`, for
  # everyone (every page needs a title that says what it is, so the visitor steps of onboarding get theirs too). With no
  # page name, signed-out visitors get the bare brand (the landing page) and signed-in users "Home - Battletown". Views
  # pass only the page name; the brand is added here.
  def page_title
    # content_for escapes what it is given and the layout escapes the whole title again, so "You're in!" would show
    # as "You&#39;re in!" in the tab: unescape once here and let the layout do the one escape.
    page = content_for(:title).presence
    return TITLE_BRAND if page.nil? && !signed_in?

    "#{page ? CGI.unescapeHTML(page.to_s) : 'Home'} - #{TITLE_BRAND}"
  end

  # A header link that says which page you are on: aria-current="page" on the current section, so screen readers and
  # the stylesheet agree. `section` is the path prefix (or a list of them) that counts as "this page": the link's own
  # path by default, and "/profile" plus "/players" for the Profile link, since a player's page is a profile too.
  def nav_link(label, path, section: path)
    current = Array(section).any? { |prefix| request.path == prefix || request.path.start_with?("#{prefix}/") }
    link_to label, path, class: ("is-current" if current), "aria-current": ("page" if current)
  end

  # The one link to Hack Club's global terms and privacy policy (Legal::URL): same tab, no referrer, and its text is its name.
  def legal_link(text = Legal::LINK_TEXT, **options)
    link_to text, Legal::URL, rel: "noopener noreferrer", **options
  end
end
