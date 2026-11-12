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
  # The address lookup at checkout (POST /auth/hack_club_address) has its own per-person limit below: counting it here too would let
  # a classroom behind one address block each other from ordering.
  # The path as the router and OmniAuth will read it: lower case (OmniAuth matches its paths case-insensitively), repeated slashes
  # squeezed. A throttle that matches the raw path is walked around by changing the case or adding a slash.
  def self.path_of(req) = req.path.downcase.squeeze("/")

  throttle("auth/ip", limit: 10, period: 1.minute) do |req|
    path = path_of(req)
    req.ip if req.post? && ((path.start_with?("/auth/") && !path.match?(%r{\A/auth/hack_club_address(?:\.\w+)?/?\z})) || path == "/dev_login")
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

  # Staff user management (/admin/users): adjustments, notes and their confirm steps are human-sized, so a small limit per
  # address stops a stuck script or a stolen session from rewriting ledgers. Reading the list and a person's page has a
  # roomier limit of its own (it is how an attacker would trawl teenagers' details). Staff are a handful of people behind
  # one or two addresses; both limits are far above real use.
  throttle("admin_users_write/ip", limit: 30, period: 1.minute) do |req|
    req.ip if req.path.start_with?("/admin/users") && !req.get? && !req.head?
  end
  throttle("admin_users_read/ip", limit: 120, period: 1.minute) do |req|
    req.ip if req.path.start_with?("/admin/users") && (req.get? || req.head?)
  end

  # Ship screenshots (flag `ship_screenshots`, config/game.yml `ship_screenshots:`): a ship form post that carries files.
  # The size check runs here, on the Content-Length header, BEFORE Rails reads or parses the body, so an oversized upload
  # costs nothing but the 413. A multipart post with NO Content-Length (a chunked body, which no browser form sends) is
  # refused the same way, because Rack would otherwise spool the whole body to disk before the app could look at it; the
  # per-file limit is checked again on the temp file in ShipImages::Processor. A format suffix or a trailing slash does not
  # get around the path match (Rails routes /ships/5.json to the same action). Uploads are also limited per address.
  SHIP_FORM_PATH = %r{\A/{0,3}(?:projects/\d+/ships|ships/\d+)(?:\.\w+)?/?\z}
  SIZE_RULE = "ship-images/size".freeze

  def self.ship_upload?(req)
    (req.post? || req.patch? || req.put?) && req.path.match?(SHIP_FORM_PATH) && req.media_type == "multipart/form-data"
  end

  blocklist(SIZE_RULE) do |req|
    ship_upload?(req) && (req.content_length.nil? || req.content_length.to_i > ShipImages::Config.current.max_request_bytes)
  end

  # Shop item pictures (/admin/shop, config/game.yml `shop_items:`): the same early size check for the admin form that carries a
  # picture, so an oversized or chunked multipart body is refused before Rails parses it. Every non-GET under /admin/shop is
  # also rate limited per address.
  ADMIN_SHOP_PATH = %r{\A/{0,3}admin/shop(?:/[a-z0-9_]*)*/?\z}
  SHOP_SIZE_RULE = "admin-shop/size".freeze

  def self.shop_upload?(req)
    (req.post? || req.patch? || req.put?) && req.path.match?(ADMIN_SHOP_PATH) && req.media_type == "multipart/form-data"
  end

  blocklist(SHOP_SIZE_RULE) do |req|
    shop_upload?(req) && (req.content_length.nil? || req.content_length.to_i > ShopItems::Config.current.max_request_bytes)
  end

  throttle("admin-shop/ip", limit: 60, period: 1.minute) do |req|
    req.ip if req.path.match?(ADMIN_SHOP_PATH) && !req.get? && !req.head?
  end

  self.blocklisted_responder = lambda do |request|
    if request.env["rack.attack.matched"] == SIZE_RULE
      limits = ShipImages::Config.current
      [ 413, { "content-type" => "text/plain; charset=utf-8" },
        [ "That upload is too big. Each screenshot can be up to #{limits.max_upload_bytes / 1_000_000.0} MB and a ship can have #{limits.max_files}.\n" ] ]
    elsif request.env["rack.attack.matched"] == SHOP_SIZE_RULE
      [ 413, { "content-type" => "text/plain; charset=utf-8" },
        [ "That picture is too big. The limit is #{ShopItems::Config.current.max_upload_bytes / 1_000_000.0} MB.\n" ] ]
    else
      [ 403, { "content-type" => "text/plain; charset=utf-8" }, [ "Forbidden\n" ] ]
    end
  end

  throttle("ship-images/ip", limit: ->(_req) { ShipImages::Config.current.uploads_per_10_minutes }, period: 10.minutes) do |req|
    req.ip if ship_upload?(req)
  end

  # Staff project reviews (POST /admin/projects/:id/ok|flag|clear|note): a person clicking a button, so a modest limit per
  # address keeps a stuck script or a stolen session from writing history in bulk. Reading the queue is not limited here.
  throttle("admin_project_reviews/ip", limit: 30, period: 1.minute) do |req|
    req.ip if req.post? && path_of(req).match?(%r{\A/admin/projects/\d+/(?:ok|flag|clear|note)(?:\.\w+)?/?\z})
  end

  # Every other staff write (ship decisions that pay coins, reveal of a survey writer, dissolving a crew, merch claims, flags,
  # quests, bosses ...): a person clicking buttons. The specific limits above are stricter for their own paths; this one is the
  # floor for all of /admin, so a stolen session or a stuck script cannot change things in bulk.
  throttle("admin_writes/ip", limit: 120, period: 1.minute) do |req|
    req.ip if !req.get? && !req.head? && path_of(req).start_with?("/admin/")
  end

  # Email unsubscribe links (GET shows the page, POST acts): human-sized, and a small limit keeps token guessing and
  # scanner floods cheap. Its own bucket, so a flood here never uses up anything else.
  throttle("email_unsubscribe/ip", limit: 20, period: 1.minute) do |req|
    req.ip if req.path.start_with?("/email/unsubscribe/") && req.get?
  end
  # The one-click POST (RFC 8058) comes from mail providers' shared addresses, and a refused one is an unsubscribe that
  # silently did not happen: its own, much larger bucket.
  throttle("email_unsubscribe_post/ip", limit: 600, period: 1.minute) do |req|
    req.ip if req.path.start_with?("/email/unsubscribe/") && req.post?
  end

  # Hack Club's data-deletion service calls /api/privacy/* from a few addresses: a generous limit of its own, kept
  # out of the general throttle below so a burst of requests there can never block it.
  throttle("privacy/ip", limit: 120, period: 1.minute) do |req|
    req.ip if req.path.start_with?("/api/privacy/")
  end

  ORDER_EXPORT_PATH = %r{\A/{1,3}admin/orders/export(?:\.\w+)?/?\z}

  # Orders. Placing one is a person clicking a button: a per-person limit per hour (config/orders.yml, default 10) keeps a
  # script from hammering the shop lock (the person is read from the session; no session, no throttle here, and the order
  # service needs a signed-in person anyway). Staff changes (hold, ship, cancel, note ... and the CSV export) have their own
  # limits per address, so a runaway script or a stuck double click loop cannot flood the history.
  throttle("orders/user", limit: ->(_req) { Orders::Config.current.orders_per_hour }, period: 1.hour) do |req|
    req.session["user_id"].to_s.presence if req.post? && req.path.match?(%r{\A/{1,3}shop/orders(?:\.\w+)?/?\z})
  end
  throttle("admin_orders/ip", limit: ->(_req) { Orders::Config.current.staff_actions_per_minute }, period: 1.minute) do |req|
    req.ip if !req.get? && !req.head? && req.path.match?(%r{\A/{1,3}admin/orders(?:/|\.|\z)}) && !req.path.match?(ORDER_EXPORT_PATH)
  end
  throttle("admin_orders_export/ip", limit: ->(_req) { Orders::Config.current.exports_per_10_minutes }, period: 10.minutes) do |req|
    req.ip if req.post? && req.path.match?(ORDER_EXPORT_PATH)
  end

  # Shipping addresses (config/orders.yml). Starting the Hack Club Auth address round trip is a person clicking a button: a small
  # limit per person (the session's user id; no session, no throttle here, and the strategy refuses anyone not signed in). The way
  # back (the callback) costs a token exchange and an API call, so it is limited per address too. Opening a full address as staff
  # is limited per staff member per hour, on top of the general staff limit per address.
  throttle("address_lookup/user", limit: ->(_req) { Orders::Config.current.address_lookups_per_10_minutes }, period: 10.minutes) do |req|
    req.session["user_id"].to_s.presence if req.post? && path_of(req).match?(%r{\A/auth/hack_club_address(?:\.\w+)?/?\z})
  end
  throttle("address_callback/ip", limit: 20, period: 1.minute) do |req|
    req.ip if path_of(req).match?(%r{\A/auth/hack_club_address/callback(?:\.\w+)?/?\z})
  end
  throttle("admin_address_reveals/user", limit: ->(_req) { Orders::Config.current.address_reveals_per_hour }, period: 1.hour) do |req|
    req.session["user_id"].to_s.presence if req.post? && req.path.match?(%r{\A/{1,3}admin/orders/\d+/address/reveal(?:\.\w+)?/?\z})
  end

  throttle("req/ip", limit: 300, period: 5.minutes) do |req|
    req.ip unless req.path.start_with?("/assets/", "/up", "/api/privacy/")
  end
end
