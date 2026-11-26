module Analytics
  # Included in ApplicationController. Gives every controller `track_event`, makes the first page request of a session create its visit,
  # records the day of presence for a signed-in person, and carries the visit through sign-in (see ApplicationController#sign_in).
  #
  #   track_event(:order_placed, item_key: order.prize_key, coins: order.coins, kind: "purchase")
  #   track_event(:todo_used, items: 2, once: "todo:#{local_date}")
  #
  # The event and its properties are checked against config/analytics.yml exactly as Analytics.track does. Nothing is recorded for a bot, a prefetch,
  # a request that sends Do Not Track or Global Privacy Control, staff and simulated players, or while the kill switch is on.
  module Controller
    extend ActiveSupport::Concern

    included do
      after_action :analytics_note_navigation
    end

    private

    def track_event(name, once: nil, **props)
      return if analytics_request.ignorable?

      Analytics.track(name, user: current_user, visit: -> { analytics_visit }, once: once, **props)
    end

    def analytics_request = @analytics_request ||= RequestInfo.new(request)

    # This session's visit: found by the token, and for a page navigation started when there is none. nil for anything else without one.
    def analytics_visit
      return @analytics_visit if defined?(@analytics_visit)

      @analytics_visit = Visitor.new(session).find_or_start(analytics_request, entry_route: "#{controller_path}##{action_name}",
                                                            user: current_user, start: analytics_request.navigation?(controller_path))
    end

    # After every action: a page the person got (HTML, not an error) opens the session's visit and counts the day.
    def analytics_note_navigation
      return unless analytics_request.navigation?(controller_path) && response.status < 400 && (response.redirect? || response.media_type == "text/html")
      return if Analytics.paused? || (current_user && Analytics.excluded?(current_user))

      Analytics.safely("page_visit") do
        analytics_visit
        AnalyticsSiteDay.touch(current_user) if current_user
      end
    end

    # The visit token (and when it was last used) the session holds now, to keep through a session reset.
    def analytics_token = Visitor.new(session).carry

    # After sign_in has reset the session and set the user: keep the visit and stamp it with the person (or drop it for staff and test players).
    def analytics_link_visit(user, previous_token)
      remove_instance_variable(:@analytics_visit) if defined?(@analytics_visit)
      Analytics.safely("link_visit") { Visitor.new(session).link!(user, previous_token) }
    end
  end
end
