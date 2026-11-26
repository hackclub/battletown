# Test helpers for first-party analytics (Analytics.track / track_event). Included in every test case from test_helper.rb.
#
#   assert_tracked(:order_placed, item_key: "sticker_pack", coins: 20)   # an event with at least these properties exists (returns it)
#   assert_not_tracked(:order_placed)                                    # none with that name
#
# A request records analytics only when it looks like a browser: a request with no user agent counts as a script, so integration tests that
# expect a visit or an event pass `headers: browser_headers`. Production never writes in tests unless a test fires an event itself.
module AnalyticsHelper
  BROWSER_USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15".freeze

  # The per-address visit counts live in Rack::Attack's in-process store, which would carry from one test to the next.
  def self.included(base) = base.setup { Analytics::VisitLimit.reset! }

  def browser_headers(extra = {}) = { "User-Agent" => BROWSER_USER_AGENT }.merge(extra)

  def assert_tracked(name, **props)
    scope = AnalyticsEvent.where(name: name.to_s)
    scope = scope.where("props @> ?::jsonb", Analytics::Events.clean(name, props).to_json) if props.any?
    event = scope.order(:id).last
    assert event, "expected a tracked #{name} event#{" with #{props}" if props.any?}, found: #{AnalyticsEvent.where(name: name.to_s).pluck(:props).inspect}"
    event
  end

  def assert_not_tracked(name)
    assert_equal 0, AnalyticsEvent.where(name: name.to_s).count, "expected no #{name} event to be tracked"
  end
end
