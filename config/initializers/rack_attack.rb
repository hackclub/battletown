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

  # Account data export and deletion (/account, /account/export, /account/delete, /account/reauth).
  throttle("account/ip", limit: 20, period: 1.minute) do |req|
    req.ip if req.path == "/account" || req.path.start_with?("/account/")
  end

  throttle("req/ip", limit: 300, period: 5.minutes) do |req|
    req.ip unless req.path.start_with?("/assets/", "/up")
  end
end
