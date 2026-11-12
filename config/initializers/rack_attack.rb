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

  # Crew invite links (/team/join/<token>): a person opens one link, maybe twice; a script guessing tokens is stopped long
  # before it matters (tokens are 96 random bits). Crew changes (create, rename, new link, leave) are human-sized too.
  throttle("team/ip", limit: 30, period: 1.minute) do |req|
    req.ip if req.path.start_with?("/team/join/") || (req.path.start_with?("/team") && !req.get?)
  end

  # Plinko: dropping a ball, opting in and getting a new nickname are human-sized actions (a ball is also limited by the
  # bank), so a limit per address that still leaves room for several people behind one shared network address.
  throttle("plinko/ip", limit: 120, period: 1.minute) do |req|
    req.ip if req.path.start_with?("/plinko") && !req.get?
  end

  # Ship screenshots (flag `ship_screenshots`, config/game.yml `ship_screenshots:`): a ship form post that carries files.
  # The size check runs here, on the Content-Length header, BEFORE Rails reads or parses the body, so an oversized upload
  # costs nothing but the 413 (a request without the header carries no file the app will accept; the per-file limit is
  # checked again on the temp file in ShipImages::Processor). Uploads are also limited per address.
  SHIP_FORM_PATH = %r{\A(?:/projects/\d+/ships|/ships/\d+)/?\z}
  SIZE_RULE = "ship-images/size".freeze

  def self.ship_upload?(req)
    (req.post? || req.patch? || req.put?) && req.path.match?(SHIP_FORM_PATH) && req.media_type == "multipart/form-data"
  end

  blocklist(SIZE_RULE) do |req|
    ship_upload?(req) && req.content_length.to_i > ShipImages::Config.current.max_request_bytes
  end

  self.blocklisted_responder = lambda do |request|
    if request.env["rack.attack.matched"] == SIZE_RULE
      limits = ShipImages::Config.current
      [ 413, { "content-type" => "text/plain; charset=utf-8" },
        [ "That upload is too big. Each screenshot can be up to #{limits.max_upload_bytes / 1_000_000.0} MB and a ship can have #{limits.max_files}.\n" ] ]
    else
      [ 403, { "content-type" => "text/plain; charset=utf-8" }, [ "Forbidden\n" ] ]
    end
  end

  throttle("ship-images/ip", limit: ->(_req) { ShipImages::Config.current.uploads_per_10_minutes }, period: 10.minutes) do |req|
    req.ip if ship_upload?(req)
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
