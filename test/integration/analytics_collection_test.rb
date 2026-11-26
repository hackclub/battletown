require "test_helper"

# First-party analytics, collection layer: when a visit is created (and when not), what it may hold, the token in the session,
# how it is attached to a person at sign-in, and what is never recorded.
class AnalyticsCollectionTest < ActionDispatch::IntegrationTest
  EMAILISH = "probe.teen@example.com".freeze
  SECRET_REFERER = "https://www.google.com/search?q=PROBE-QUERY&token=PROBE-SECRET".freeze
  IP = "203.0.113.77".freeze

  setup do
    OmniAuth.config.test_mode = true
    @original_admins = ENV["ADMIN_HCA_UIDS"]
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
    @original_admins.nil? ? ENV.delete("ADMIN_HCA_UIDS") : ENV["ADMIN_HCA_UIDS"] = @original_admins
  end

  def sign_in_as(user, headers: browser_headers)
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club", headers: headers
    follow_redirect!
  end

  def analytics_queries
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] if payload[:sql].match?(/analytics_/) && payload[:name] != "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    queries
  end

  # --- when a visit is created ---

  test "the first page request of a session creates a visit with a random token held only in the session" do
    get "/", headers: browser_headers

    visit = AnalyticsVisit.sole
    assert_equal session[:av], visit.visit_key
    assert_match(/\A[A-Za-z0-9_-]{22}\z/, visit.visit_key)
    assert_equal "landing#show", visit.entry_route
    assert_equal %w[direct desktop], [ visit.referrer_kind, visit.device_class ]
    assert_nil visit.user_id
    assert_in_delta Time.current, visit.started_at, 10

    get "/", headers: browser_headers
    assert_equal 1, AnalyticsVisit.count, "the token is kept: one visit per session"
    assert_equal visit.visit_key, session[:av]
  end

  test "the token is random: two sessions never share one, and it is not derived from the address or the browser" do
    get "/", headers: browser_headers
    first = session[:av]
    reset!
    get "/", headers: browser_headers
    assert_not_equal first, session[:av]
    assert_equal 2, AnalyticsVisit.count
  end

  test "a referral link visit keeps the slug and allowlisted utm values, and the referrer only as a kind" do
    get "/haven?utm_source=Reddit&utm_medium=#{EMAILISH}&utm_campaign=unlisted-campaign&utm_content=PROBE-CONTENT&utm_term=PROBE-TERM",
        headers: browser_headers("Referer" => SECRET_REFERER)

    assert_redirected_to root_path
    visit = AnalyticsVisit.sole
    assert_equal "haven", visit.referral_slug
    assert_equal %w[reddit other other], [ visit.utm_source, visit.utm_medium, visit.utm_campaign ]
    assert_equal "search", visit.referrer_kind
    assert_equal "referrals#show", visit.entry_route
    dumped = AnalyticsVisit.pluck(*AnalyticsVisit.column_names).flatten.join(" ")
    %w[PROBE google.com utm_content].each { |leak| assert_no_match(/#{leak}/i, dumped) }
  end

  test "the slug carried in the session is the visit's when the first page was not the link" do
    get "/haven", headers: browser_headers
    AnalyticsVisit.delete_all
    reset!
    get "/", headers: browser_headers
    assert_nil AnalyticsVisit.sole.referral_slug
  end

  test "referrer kinds are decided from the host alone" do
    {
      "https://hackclub.slack.com/archives/C1?thread=PROBE" => "hack_club", "https://www.reddit.com/r/x/comments/PROBE" => "social",
      "https://duckduckgo.com/?q=PROBE" => "search", "https://random.example.org/PROBE" => "other", "not a url at all" => "other",
      "ftp://files.example.net/PROBE" => "other"
    }.each do |referer, kind|
      reset!
      AnalyticsVisit.delete_all
      get "/", headers: browser_headers("Referer" => referer)
      assert_equal kind, AnalyticsVisit.sole.referrer_kind, referer
    end
    reset!
    AnalyticsVisit.delete_all
    get "/", headers: browser_headers("Referer" => "http://www.example.com/dashboard") # this site's own host is "www.example.com" in tests
    assert_equal "direct", AnalyticsVisit.sole.referrer_kind
  end

  test "the device class is a coarse bucket and the user agent itself is never stored" do
    { "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1" => "mobile",
      "Mozilla/5.0 (iPad; CPU OS 17_4 like Mac OS X) AppleWebKit/605.1.15 Safari/604.1" => "tablet",
      AnalyticsHelper::BROWSER_USER_AGENT => "desktop" }.each do |agent, device|
      reset!
      AnalyticsVisit.delete_all
      get "/", headers: { "User-Agent" => agent }
      assert_equal device, AnalyticsVisit.sole.device_class
      assert_no_match(/Mozilla|AppleWebKit|Safari/, AnalyticsVisit.pluck(*AnalyticsVisit.column_names).flatten.join(" "))
    end
  end

  # --- what is never a visit ---

  test "bots, previews, scripts, prefetches, opt-outs, HEAD, JSON, XHR, frames, health checks and the staff area record nothing" do
    ENV["ADMIN_HCA_UIDS"] = users(:onboarded).hca_uid
    attempts = {
      "a crawler" => [ :get, "/", browser_headers.merge("User-Agent" => "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)") ],
      "a Slack unfurl" => [ :get, "/", { "User-Agent" => "Slackbot-LinkExpanding 1.0 (+https://api.slack.com/robots)" } ],
      "curl" => [ :get, "/", { "User-Agent" => "curl/8.4.0" } ],
      "no user agent" => [ :get, "/", { "User-Agent" => "" } ],
      "a link preview" => [ :get, "/", { "User-Agent" => "Mozilla/5.0 (Windows NT 10.0) WhatsApp/2.23 Preview" } ],
      "a prefetch" => [ :get, "/", browser_headers("Sec-Purpose" => "prefetch;prerender") ],
      "a Turbo prefetch" => [ :get, "/", browser_headers("X-Sec-Purpose" => "prefetch") ],
      "Global Privacy Control" => [ :get, "/", browser_headers("Sec-GPC" => "1") ],
      "Do Not Track" => [ :get, "/", browser_headers("DNT" => "1") ],
      "a JSON request" => [ :get, "/", browser_headers("Accept" => "application/json") ],
      "an XHR" => [ :get, "/", browser_headers("X-Requested-With" => "XMLHttpRequest") ],
      "a Turbo Frame" => [ :get, "/", browser_headers("Turbo-Frame" => "panel") ],
      "HEAD" => [ :head, "/", browser_headers ],
      "the health check" => [ :get, "/up", browser_headers ],
      "a page that does not exist" => [ :get, "/no/such/page", browser_headers ]
    }

    attempts.each do |what, (verb, path, headers)|
      reset!
      send(verb, path, headers: headers)
      assert_equal 0, AnalyticsVisit.count, "#{what} must not create a visit"
      assert_nil session[:av], "#{what} must not get a token"
    end
    assert_equal 0, AnalyticsEvent.count
  end

  test "a POST never starts a visit, and the admin and dev areas are never measured" do
    post "/dev_login", headers: browser_headers
    assert_equal 0, AnalyticsVisit.count

    ENV["ADMIN_HCA_UIDS"] = users(:onboarded).hca_uid
    sign_in_as users(:onboarded)
    assert_equal 0, AnalyticsVisit.count
    get "/admin", headers: browser_headers
    assert_response :success
    assert_equal 0, AnalyticsVisit.count + AnalyticsSiteDay.count
  end

  test "the kill switch stops visits and presence, and turning it off starts them again" do
    with_feature(:analytics_paused) { get "/", headers: browser_headers }
    assert_equal 0, AnalyticsVisit.count
    get "/", headers: browser_headers
    assert_equal 1, AnalyticsVisit.count
  end

  # --- people: attaching the visit at sign-in ---

  test "signing in keeps the token, stamps the visit and every event of it with the person, and deleting the person deletes them" do
    get "/haven", headers: browser_headers
    visit = AnalyticsVisit.sole
    AnalyticsEvent.delete_all # (the link and the landing page record their own events; these two are made by hand)
    Analytics.track(:landing_viewed, visit: visit)
    Analytics.track(:onboarding_step_viewed, visit: visit, step: "age")
    assert_equal [ nil, nil ], AnalyticsEvent.pluck(:user_id)

    assert_difference "User.count", 1 do
      sign_in_as User.new(hca_uid: "ident!fresh")
    end

    user = User.find_by!(hca_uid: "ident!fresh")
    assert_equal visit.visit_key, session[:av], "the token survives the session reset at sign-in"
    assert_equal user.id, visit.reload.user_id
    assert_equal [ user.id, user.id ], AnalyticsEvent.where(visit_id: visit.id, name: %w[landing_viewed onboarding_step_viewed]).pluck(:user_id)
    assert_equal [ user.id ], AnalyticsEvent.where(name: "signup_started").pluck(:user_id), "the sign-up press was anonymous and is the person's now"

    User.where(id: user.id).delete_all # (the database cascade Privacy::Deleter relies on)
    assert_equal 0, AnalyticsVisit.count + AnalyticsEvent.count
  end

  test "a person who signs in with no visit yet gets one on their next page, stamped with them" do
    sign_in_as users(:onboarded)
    assert_nil session[:av]

    get "/dashboard", headers: browser_headers
    assert_equal users(:onboarded).id, AnalyticsVisit.sole.user_id
    assert_equal [ users(:onboarded).id ], AnalyticsSiteDay.pluck(:user_id)
  end

  test "signing out ends the visit: the next page opens a new one" do
    get "/", headers: browser_headers
    sign_in_as users(:onboarded)
    first = session[:av]
    delete logout_path, headers: browser_headers
    assert_nil session[:av]
    get "/", headers: browser_headers
    assert_not_equal first, session[:av]
    assert_equal 2, AnalyticsVisit.count
  end

  test "a second person signing in on the same browser does not take over the first person's visit" do
    get "/", headers: browser_headers
    sign_in_as users(:onboarded)
    first = AnalyticsVisit.sole

    sign_in_as users(:new_user) # no sign-out in between: a shared computer
    assert_nil session[:av]
    assert_equal users(:onboarded).id, first.reload.user_id

    get "/", headers: browser_headers
    second = AnalyticsVisit.where(user_id: users(:new_user).id).sole
    assert_not_equal first.visit_key, second.visit_key
  end

  test "staff have their anonymous trail deleted at sign-in and are never recorded afterwards" do
    ENV["ADMIN_HCA_UIDS"] = users(:onboarded).hca_uid
    get "/", headers: browser_headers
    assert_equal 1, AnalyticsEvent.where(name: "landing_viewed").count # the landing page records its own view
    AnalyticsSiteDay.create!(user: users(:onboarded), day: Date.new(2026, 11, 9)) # something recorded before they were listed

    sign_in_as users(:onboarded)

    assert_equal 0, AnalyticsVisit.count + AnalyticsEvent.count + AnalyticsSiteDay.count
    assert_nil session[:av]
    assert users(:onboarded).reload.analytics_excluded?
    get "/dashboard", headers: browser_headers
    assert_equal 0, AnalyticsVisit.count + AnalyticsSiteDay.count
  end

  test "a simulated player and a listed tester are excluded the same way" do
    ENV["ANALYTICS_EXCLUDE_HCA_UIDS"] = "ident!tester"
    %w[sim!9 ident!tester].each do |uid|
      reset!
      get "/", headers: browser_headers
      assert_equal 1, AnalyticsVisit.count
      sign_in_as User.new(hca_uid: uid)
      get "/", headers: browser_headers
      assert_equal 0, AnalyticsVisit.count + AnalyticsSiteDay.count, uid
    end
  ensure
    ENV.delete("ANALYTICS_EXCLUDE_HCA_UIDS")
  end

  test "an excluded person's sign-in leaves another person's visit on that browser alone" do
    ENV["ADMIN_HCA_UIDS"] = users(:onboarded).hca_uid
    get "/", headers: browser_headers
    other = AnalyticsVisit.sole
    other.update!(user: users(:new_user))

    sign_in_as users(:onboarded)
    assert_equal [ other.id ], AnalyticsVisit.pluck(:id)
  end

  test "a signed-in person's days of presence are recorded once a day" do
    sign_in_as users(:onboarded)
    3.times { get "/dashboard", headers: browser_headers }
    assert_equal 1, AnalyticsSiteDay.where(user: users(:onboarded)).count

    get "/dashboard", headers: browser_headers("Sec-GPC" => "1")
    travel 1.day do
      get "/dashboard", headers: browser_headers("DNT" => "1")
    end
    assert_equal 1, AnalyticsSiteDay.where(user: users(:onboarded)).count, "an opted-out request leaves nothing"
    travel 1.day do
      get "/dashboard", headers: browser_headers
    end
    assert_equal 2, AnalyticsSiteDay.where(user: users(:onboarded)).count
  end

  # --- a controller records events through the one helper ---

  test "track_event records for the session's visit and the signed-in person, and not for a bot or an opted-out request" do
    get "/", headers: browser_headers
    visit = AnalyticsVisit.sole
    controller_event = ->(headers) { get "/", headers: headers }
    original = LandingController.instance_method(:show)
    LandingController.define_method(:show) { track_event(:landing_viewed); original.bind_call(self) }

    controller_event.call(browser_headers)
    event = assert_tracked(:landing_viewed)
    assert_equal visit.id, event.visit_id
    assert_nil event.user_id

    sign_in_as users(:new_user)
    AnalyticsEvent.delete_all
    controller_event.call(browser_headers)
    assert_equal [ users(:new_user).id, visit.id ], assert_tracked(:landing_viewed).then { |signed_in| [ signed_in.user_id, signed_in.visit_id ] }

    AnalyticsEvent.delete_all
    controller_event.call(browser_headers("Sec-GPC" => "1"))
    controller_event.call(browser_headers("User-Agent" => "curl/8"))
    assert_not_tracked :landing_viewed
  ensure
    LandingController.define_method(:show, original) if original
  end

  # --- limits ---

  test "an address that starts more than the allowed visits in ten minutes without a cookie gets no more, and signed-in people are never counted" do
    assert_operator Analytics::VisitLimit.limit, :>=, 50, "sized for a classroom behind one address"
    stub_method(Analytics::VisitLimit, :limit, -> { 3 }) do
      5.times do
        reset!
        get "/", headers: browser_headers
      end
      assert_equal 3, AnalyticsVisit.count
      assert_equal 3, AnalyticsEvent.where(name: "landing_viewed").count, "no visit, no anonymous event"

      sign_in_as users(:onboarded)
      assert_difference -> { AnalyticsVisit.count }, 1 do
        get "/dashboard", headers: browser_headers
      end
    end
  end

  test "a visit goes stale after half an hour idle: the next page starts a new one, and a stale anonymous trail is not stamped on whoever signs in" do
    get "/", headers: browser_headers
    first = AnalyticsVisit.sole
    travel 20.minutes
    get "/", headers: browser_headers
    assert_equal 1, AnalyticsVisit.count, "twenty minutes of quiet is the same visit"
    travel 31.minutes
    get "/", headers: browser_headers
    assert_equal 2, AnalyticsVisit.count
    assert_not_equal first.visit_key, session[:av]

    reset!
    get "/", headers: browser_headers
    stale = AnalyticsVisit.order(:id).last
    travel 2.hours
    sign_in_as users(:onboarded)
    assert_nil stale.reload.user_id, "an anonymous trail left on a shared computer is nobody's"
  end

  # --- cost and size ---

  test "a first page costs one analytics insert, a later page one lookup, a signed-in page a lookup and a presence check" do
    # The onboarding page records its own step event: the first request inserts the visit and the event, a later one looks the visit up and inserts the event.
    first = analytics_queries { get "/onboarding/age", headers: browser_headers }
    assert_equal [ "INSERT INTO \"analytics_visits\"", "INSERT INTO \"analytics_events\"" ], first.map { |sql| sql[/\AINSERT INTO "\w+"/] }, first.inspect
    later = analytics_queries { get "/onboarding/age", headers: browser_headers }
    assert_equal 2, later.size, later.inspect
    assert_equal 1, later.count { |sql| sql.start_with?("SELECT") }

    sign_in_as users(:onboarded)
    queries = analytics_queries { get "/dashboard", headers: browser_headers }
    assert_operator queries.size, :<=, 3, queries.inspect
    assert_operator analytics_queries { get "/dashboard", headers: browser_headers }.size, :<=, 3
  end

  test "the session cookie with the biggest possible onboarding draft and the visit token still fits" do
    week = %w[monday tuesday wednesday thursday friday saturday sunday]
    get "/haven", headers: browser_headers
    assert session[:av]
    patch onboarding_step_path("age"), params: { user: { age_group: "teen" } }, headers: browser_headers
    patch onboarding_step_path("prize"), params: { user: { prize_key: "tshirt" } }, headers: browser_headers
    patch onboarding_step_path("project"), params: { user: { project_kind: "game", project_idea: "😀" * 300 } }, headers: browser_headers
    patch onboarding_step_path("schedule"), headers: browser_headers,
          params: { user: { coding_day_names: week, coding_time: "18:30", time_zone: "UTC", pace_minutes: "240", coding_times: week.to_h { |day| [ day, "23:59" ] } } }

    assert_redirected_to onboarding_step_path("signup")
    assert session[:av], "the token is still in the session"
    assert_operator response.headers["set-cookie"].to_s[/_[a-z_]+session=[^;]*/].bytesize, :<, 3600
  end

  # --- privacy ---

  test "after a whole visit and sign-up no analytics row holds an address, a user agent, a referrer, an email, a name or a typed answer" do
    claims = { "email" => EMAILISH, "name" => "Probe Teenager", "slack_id" => "U0PROBE123", "verification_status" => "verified" }
    get "/haven?utm_source=#{EMAILISH}", headers: browser_headers("Referer" => SECRET_REFERER, "REMOTE_ADDR" => IP, "X-Forwarded-For" => IP), env: { "REMOTE_ADDR" => IP }
    patch onboarding_step_path("project"), params: { user: { project_kind: "game", project_idea: "PROBE-IDEA-TEXT" } }, headers: browser_headers
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: "ident!probe", extra: { raw_info: claims })
    post "/auth/hack_club", headers: browser_headers
    follow_redirect!
    get "/onboarding", headers: browser_headers

    user = User.find_by!(hca_uid: "ident!probe")
    rows = [ AnalyticsVisit, AnalyticsEvent, AnalyticsSiteDay, JobRun, AnalyticsDailySnapshot ].flat_map do |model|
      model.all.map { |record| record.attributes.values.join(" ") }
    end.join(" ")
    [ IP, "Mozilla", "Safari", "PROBE", "google.com", EMAILISH, "Probe Teenager", "U0PROBE123", user.hca_uid, "ident!probe" ].each do |secret|
      assert_not_includes rows, secret
    end
    assert_operator AnalyticsVisit.count, :>=, 1
  end
end
