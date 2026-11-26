# First-party analytics: the collection layer (projects/battletown/plans/analytics.md). No third-party service, no new gem, no JavaScript.
#
#   Analytics.track(:ship_approved, user: ship.user, hours_bucket: "2-5", nth: "1", waited: "1d")   # services, models, jobs, rake tasks
#   Analytics.track(:quick_day_reached, user: user, once: "quick:#{local_date}")                      # idempotent per user (a repeat is a no-op)
#   track_event(:order_placed, item_key: "sticker_pack", coins: 20, kind: "purchase")                 # in a controller: the visit comes from the session
#
# The event and every property must be in config/analytics.yml (Analytics::Events). A typo raises in test and development; in production the
# event is dropped and its name (never its properties) is logged, and nothing ever raises into the request. Always returns nil. Records nothing
# while the Flipper flag `analytics_paused` is on (or ANALYTICS_DISABLED=true), for staff, simulated and listed test players, or for a
# request that is a bot, a prefetch or sends Do Not Track / Global Privacy Control (Analytics::Controller; only an event fired from a request can see
# those headers, so a service-fired event for a signed-in person is recorded regardless: plans/analytics.md, 1.3). Call it after the write succeeded:
# inside a transaction the event is written when the outermost one commits (and never if it rolls back).
#
# Nothing here is deleted on a schedule, ever: no retention job, no TTL. The only deletions are the cascade from users (Privacy::Deleter, when a
# person or Hack Club asks) and an operator acting by hand.
module Analytics
  # Boot-time off switch next to the flag, for when the database is not reachable to flip it.
  DISABLE_ENV = "ANALYTICS_DISABLED".freeze
  PAUSE_FLAG = :analytics_paused
  # The flag is read at most this often per process (flipping it at /admin/flipper takes effect within this long); tests read it every time.
  PAUSE_CACHE_SECONDS = Rails.env.test? ? 0 : 30

  class << self
    # `visit` may be an AnalyticsVisit or a callable that returns one (it runs only if the event is going to be written).
    def track(name, user: nil, visit: nil, once: nil, **props)
      cleaned = Events.clean(name, props)
      raise Events::Invalid, "once: needs a user" if once && user.nil?

      return if paused? || (user && excluded?(user))

      ActiveRecord.after_all_transactions_commit do
        safely(name) { Tracker.write(name, cleaned, user: user, visit: visit.respond_to?(:call) ? visit.call : visit, once: once) }
      end
      nil
    rescue StandardError => error
      raise if strict?

      log_dropped(name, error)
      nil
    end

    # True while tracking is switched off (the flag, or the env var), so nothing is written.
    def paused?
      return true if ActiveModel::Type::Boolean.new.cast(ENV[DISABLE_ENV])

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if @paused_read_at.nil? || now - @paused_read_at >= PAUSE_CACHE_SECONDS
        @paused = Features.enabled?(PAUSE_FLAG)
        @paused_read_at = now
      end
      @paused
    end

    # Staff, simulated players and listed test players are never measured, whatever the stored flag says (a list can change between sign-ins).
    def excluded?(user) = user.analytics_excluded? || Exclusion.uid?(user.hca_uid)

    # Raise on a mistake in test and development (so a typo fails CI); in production never let analytics break a page.
    def strict? = !Rails.env.production?

    # Runs the block; a failure is raised when strict, and otherwise logged by class name only.
    def safely(label = "analytics")
      yield
    rescue StandardError => error
      raise if strict?

      log_dropped(label, error)
      nil
    end

    private

    def log_dropped(name, error)
      Rails.logger.warn("Analytics: dropped #{name.to_s.first(40).inspect} (#{error.class})")
    end
  end
end
