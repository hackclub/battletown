module Analytics
  # What one request may contribute to a visit, and the filters that keep non-people and non-pages out (plans/analytics.md, section 1.5).
  #
  # READ, then reduced at once to an enum or an allowlisted value and discarded: the path segment of a referral link, the utm_* params, the
  # Referer HOST (to a kind), the user agent (to a device class, and tested for bot-ness), Sec-GPC / DNT, the prefetch headers.
  # NEVER read into storage: the IP address (in any form), the user agent string, the full Referer, the URL or query string, Accept-Language,
  # screen size, any cookie but our own token, anything from a body.
  class RequestInfo
    # Slack unfurls of a shared link, previews, uptime monitors and scripts would otherwise count as landing views. A request with no user agent
    # at all is a script too: every browser sends one.
    BOT = /bot|crawl|spider|slurp|preview|facebookexternalhit|slackbot|discord|telegram|whatsapp|curl|wget|headless|monitor|uptime|python|java|go-http|okhttp|axios|node-fetch|libwww|httpclient/i
    PREFETCH_HEADERS = %w[Sec-Purpose X-Sec-Purpose Purpose X-Purpose X-Moz].freeze
    PREFETCH = /prefetch|prerender|preview/i
    # The first path segment of a controller that is never measured: the staff area, development tools and the data-deletion API.
    UNTRACKED_AREAS = %w[admin dev api].freeze
    UTM = { utm_source: :utm_sources, utm_medium: :utm_mediums, utm_campaign: :utm_campaigns }.freeze
    OTHER = "other".freeze

    def initialize(request)
      @request = request
    end

    # Do Not Track or Global Privacy Control: honoured as a courtesy to minors (the funnel simply undercounts those people) for everything fired from a
    # request. Events fired by services and jobs have no request to read it from.
    def opted_out? = header("Sec-GPC") == "1" || header("DNT") == "1"

    def bot? = user_agent.blank? || BOT.match?(user_agent)

    def prefetch? = PREFETCH_HEADERS.any? { |name| PREFETCH.match?(header(name).to_s) }

    # False once this address has started VisitLimit::LIMIT visits in ten minutes (a script with no cookie jar). The address is only counted, never kept.
    def new_visit_allowed?
      VisitLimit.allow?(@request.remote_ip)
    rescue ActionDispatch::RemoteIp::IpSpoofAttackError
      VisitLimit.allow?(@request.ip)
    end

    # A request that must leave nothing behind, for a page or for an event fired during it.
    def ignorable? = bot? || prefetch? || opted_out?

    # A page navigation by a person: a plain GET for HTML (not HEAD, XHR, a Turbo Frame or a JSON/asset request) outside the staff, dev and API areas.
    # The response is checked separately (it must be HTML and not an error) once there is one.
    def navigation?(controller_path)
      @request.get? && !@request.xhr? && header("Turbo-Frame").blank? && @request.format.html? &&
        !UNTRACKED_AREAS.include?(controller_path.to_s.split("/").first) && !ignorable?
    end

    def device_class
      ua = user_agent
      if ua.blank? then "unknown"
      elsif ua.match?(/ipad|tablet|android(?!.*mobile)/i) then "tablet"
      elsif ua.match?(/mobi|iphone|ipod|android/i) then "mobile"
      else "desktop"
      end
    end

    # direct, search, social, hack_club or other, from the Referer HOST against config/analytics.yml. The host and URL are not kept.
    def referrer_kind
      host = referer_host
      return "direct" if host.blank? || host == @request.host

      Events.config.fetch(:referrer_hosts).each do |kind, domains|
        return kind.to_s if domains.any? { |domain| host == domain || host.end_with?(".#{domain}") }
      end
      OTHER
    end

    # Only a slug in config/referrals.yml: from the /:slug path of this request, else the one the session already holds.
    def referral_slug(session)
      Referral.find(@request.path_parameters[:ref])&.slug || Referral.find(session[:referral_source])&.slug
    end

    # A utm value only when it is on the allowlist in config/analytics.yml (lowercased), else the literal "other"; nil when the param is absent.
    # utm_content and utm_term are not read at all.
    def utm(param)
      value = @request.query_parameters[param.to_s]
      return unless value.is_a?(String) && value.present?

      allowed = Events.config.fetch(UTM.fetch(param.to_sym))
      allowed.include?(value.downcase) ? value.downcase : OTHER
    end

    # The columns of a new AnalyticsVisit (all of them reduced values; no URL, IP or user agent).
    def visit_attributes(session, entry_route)
      { referral_slug: referral_slug(session), utm_source: utm(:utm_source), utm_medium: utm(:utm_medium), utm_campaign: utm(:utm_campaign),
        referrer_kind: referrer_kind, device_class: device_class, entry_route: entry_route.to_s.first(80) }
    end

    private

    def header(name) = @request.headers[name]

    def user_agent = @request.user_agent.to_s

    def referer_host
      referer = @request.referer.presence or return
      URI.parse(referer).host&.downcase
    rescue URI::InvalidURIError
      OTHER
    end
  end
end
