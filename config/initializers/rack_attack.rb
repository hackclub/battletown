class Rack::Attack
  # Counters live in an explicit store so throttling never depends on the Rails.cache default. Production
  # shares Solid Cache (PostgreSQL, see config/cache.yml) across processes and restarts, wrapped so a cache
  # outage fails open instead of returning 500s. Development and test keep an in-process MemoryStore, so
  # they need no cache table (Rails.cache is a null store in test).
  cache.store = Rails.env.production? ? FailOpenCacheStore.new(Rails.cache) : ActiveSupport::Cache::MemoryStore.new(size: 4.megabytes)

  # req.ip is overridden (config/initializers/rack_attack_client_ip.rb) to match request.remote_ip: the
  # right-most X-Forwarded-For address that is not a trusted proxy, so a client-supplied header value cannot
  # be used to dodge these limits. Private ranges are always trusted; list a public CDN or load balancer
  # in the TRUSTED_PROXIES env var, otherwise all visitors share the proxy's address.
  throttle("auth/ip", limit: 10, period: 1.minute) do |req|
    req.ip if req.post? && (req.path.start_with?("/auth/") || req.path == "/dev_login")
  end

  # Hackatime linking: the callback is a GET (the POST that starts it is covered by auth/ip above), and connect /
  # disconnect are the only calls that reach out to Hackatime, so keep them to a small, human-sized rate.
  throttle("hackatime/ip", limit: 20, period: 1.minute) do |req|
    req.ip if req.path == "/auth/hackatime/callback" || (req.path == "/hackatime" && !req.get?)
  end

  # Notification preferences: saving is a human-sized action, so a small limit per address.
  throttle("settings/ip", limit: 20, period: 1.minute) do |req|
    req.ip if req.path == "/settings/notifications" && !req.get?
  end

  # The public NPS survey link: opening it or answering is a human-sized action.
  throttle("feedback/ip", limit: 30, period: 1.minute) do |req|
    req.ip if req.path.start_with?("/feedback/")
  end

  # Hack Club's data-deletion service calls /api/privacy/* from a few addresses: a generous limit of its own, kept
  # out of the general throttle below so a burst of requests there can never block it.
  throttle("privacy/ip", limit: 120, period: 1.minute) do |req|
    req.ip if req.path.start_with?("/api/privacy/")
  end

  throttle("req/ip", limit: 300, period: 5.minutes) do |req|
    req.ip unless req.path.start_with?("/assets/", "/up", "/api/privacy/")
  end
end
