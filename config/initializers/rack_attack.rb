class Rack::Attack
  # Counters live in an explicit in-process store so throttling never depends on Rails.cache, which is a
  # null store in test and an unrelated FileStore by default in production. Puma runs one process here;
  # if workers or several containers are added, switch this to a shared store (Redis or Solid Cache).
  cache.store = ActiveSupport::Cache::MemoryStore.new(size: 4.megabytes)

  # req.ip is the right-most non-private address in X-Forwarded-For, so a client-supplied header value
  # cannot be used to dodge these limits. If a public CDN sits in front of the proxy, set
  # config.action_dispatch.trusted_proxies and key on request.remote_ip instead.
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
