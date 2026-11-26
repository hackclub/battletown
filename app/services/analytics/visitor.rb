module Analytics
  # The visit behind a browser session (plans/analytics.md, section 1.4). The token is random (never derived from an IP or user agent) and
  # lives only in the encrypted session cookie that already exists (about 40 bytes); there is no new cookie. A visit is created on the
  # first page request of a session. At sign-in the visit (and every event of it) is stamped with the person, so the trail from before
  # sign-up is deleted with them; staff, simulated and listed test players have it deleted instead.
  #
  # The session cookie itself lives 30 days, so the token carries the time it was last used and goes stale after IDLE_SECONDS of no requests: the
  # next page starts a new visit. A visit is therefore one sitting, not a month, and an anonymous trail left on a shared computer is not picked up
  # by whoever signs in there later.
  class Visitor
    SESSION_KEY = :av
    SEEN_KEY = :av_at
    TOKEN_BYTES = 16 # urlsafe_base64(16) is 22 characters; the column holds 32
    IDLE_SECONDS = 30.minutes.to_i
    # The time is rewritten at most this often (the cookie is not changed on every request).
    TOUCH_SECONDS = 5.minutes.to_i

    def initialize(session)
      @session = session
    end

    # The token while this sitting is live; nil when there is none or it has been idle too long.
    def token = (@session[SESSION_KEY] if live?(@session[SEEN_KEY]))

    # What sign_in must carry across its session reset: the token and when it was last used.
    def carry = [ @session[SESSION_KEY], @session[SEEN_KEY] ]

    # The visit this session names, or nil (no live token, or its row is gone: the person was deleted, or staff purged by hand).
    def current
      return unless token.is_a?(String)

      AnalyticsVisit.find_by(visit_key: token)
    end

    # The session's visit; when there is none and `start` is true, a new one (first-touch attribution from this request).
    def find_or_start(info, entry_route:, user: nil, start: false)
      visit = current
      if visit && (user.nil? || visit.user_id.nil? || visit.user_id == user.id)
        touch
        return visit
      end
      return unless start && (user || info.new_visit_allowed?)

      begin_visit(info, entry_route: entry_route, user: user)
    end

    # At sign-in, with what the session held BEFORE it was reset (sign_in resets the session against fixation, which would otherwise drop it).
    def link!(user, carried)
      previous_token, seen = carried
      if Analytics.excluded?(user)
        Exclusion.purge!(user.id, token: previous_token)
        return forget
      end

      visit = previous_token.is_a?(String) && live?(seen) ? AnalyticsVisit.find_by(visit_key: previous_token) : nil
      # Nothing to carry (or an idle one: not this person's), or a visit another person signed in on (a shared computer): a fresh visit starts on the next page.
      return forget if visit.nil? || (visit.user_id && visit.user_id != user.id)

      AnalyticsVisit.transaction do
        visit.update!(user_id: user.id) if visit.user_id.nil?
        AnalyticsEvent.where(visit_id: visit.id, user_id: nil).update_all(user_id: user.id)
      end
      @session[SESSION_KEY] = previous_token
      @session[SEEN_KEY] = Time.current.to_i
    end

    private

    def live?(seen) = seen.is_a?(Integer) && Time.current.to_i - seen < IDLE_SECONDS

    def touch
      now = Time.current.to_i
      @session[SEEN_KEY] = now if now - @session[SEEN_KEY].to_i >= TOUCH_SECONDS
    end

    def forget
      @session.delete(SEEN_KEY)
      @session.delete(SESSION_KEY)
    end

    def begin_visit(info, entry_route:, user:)
      new_token = SecureRandom.urlsafe_base64(TOKEN_BYTES)
      visit = AnalyticsVisit.create!(visit_key: new_token, user_id: user&.id, started_at: Time.current, **info.visit_attributes(@session, entry_route))
      @session[SESSION_KEY] = new_token
      @session[SEEN_KEY] = Time.current.to_i
      visit
    end
  end
end
