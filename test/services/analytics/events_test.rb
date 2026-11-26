require "test_helper"

# The allowlist (config/analytics.yml): what an event may carry, and what can never be stored.
class AnalyticsEventsTest < ActiveSupport::TestCase
  # A property whose NAME suggests something personal must be a bool or an enum (a bounded value), never a key or a number from outside.
  PERSONAL_NAME = /email|name|slack|hca|uid|\bip\b|agent|address|text|comment|idea|url|note|reason|phone|birth|\bage\b|password|token|secret/

  def spec_type(spec) = spec == "bool" ? :bool : spec.keys.first

  test "every event name is snake_case, at most 40 characters and unique, and the file declares the events the plan lists" do
    names = Analytics::Events.names
    assert_equal names.uniq, names
    names.each { |name| assert_match Analytics::Events::NAME_FORMAT, name }
    %w[landing_viewed referral_link_hit onboarding_step_viewed onboarding_step_completed signup_started signed_up hackatime_linked project_created
       first_hours_credited quick_day_reached streak_extended ship_submitted ship_approved boss_defeated shop_viewed order_placed
       purchase_refused notification_sent nps_answered profile_viewed settings_saved].each { |name| assert_includes names, name }
  end

  test "every property is a bool, a bounded int, an enum or a key, and only the first three may be named like personal data" do
    Analytics::Events.definitions.each do |event, props|
      assert_operator props.size, :<=, Analytics::Events::MAX_PROPS, "#{event} has too many properties"
      props.each do |prop, spec|
        type = spec_type(spec)
        assert_includes %i[bool int enum key], type, "#{event}.#{prop} has an unknown type"
        assert_includes %i[bool enum], type, "#{event}.#{prop} is named like personal data but is not a bounded value" if prop.to_s.match?(PERSONAL_NAME)
        assert_equal %i[max min], spec[:int].keys.sort, "#{event}.#{prop} needs a min and a max" if type == :int
        assert_operator spec[:enum].size, :>, 0, "#{event}.#{prop} has no allowed values" if type == :enum
      end
    end
  end

  test "every enum value is a short lowercase code, never a sentence" do
    Analytics::Events.definitions.each_value do |props|
      props.each_value do |spec|
        next unless spec_type(spec) == :enum

        spec[:enum].each { |value| assert_match(/\A[a-z0-9_-]{1,20}\z/, value.to_s) }
      end
    end
  end

  test "the widest possible properties of every event fit the database check (400 bytes)" do
    Analytics::Events.names.each { |name| assert_operator Analytics::Events.max_props_bytes(name), :<=, Analytics::Events::MAX_PROPS_BYTES, name }
  end

  test "clean returns string keys, keeps the allowed value's own type and leaves nils out" do
    cleaned = Analytics::Events.clean(:onboarding_step_completed, step: :prize, prize_key: "tshirt", has_idea: true, days_count: 5, pace_minutes: 30, project_kind: nil)
    assert_equal({ "step" => "prize", "prize_key" => "tshirt", "has_idea" => true, "days_count" => 5, "pace_minutes" => 30 }, cleaned)
    assert_equal({}, Analytics::Events.clean(:landing_viewed, {}))
  end

  test "an unknown event, an unknown property or a value outside its type is refused" do
    bad = [ [ :landing_viewd, {} ], [ :landing_viewed, { email: "a@b.c" } ], [ :signed_up, { had_draft: "yes" } ], [ :todo_used, { items: 11 } ],
            [ :todo_used, { items: "2" } ], [ :auth_failed, { strategy: "hack_club", reason: "my free text" } ], [ :onboarding_step_completed, { pace_minutes: "30" } ],
            [ :onboarding_step_completed, { pace_minutes: 31 } ], [ :shop_item_viewed, { item_key: "Has Spaces" } ], [ :shop_item_viewed, { item_key: "x" * 61 } ],
            [ :shop_item_viewed, { item_key: 5 } ], [ :referral_link_hit, { slug: "not_a_referral" } ] ]
    bad.each { |name, props| assert_raises(Analytics::Events::Invalid, "#{name} #{props}") { Analytics::Events.clean(name, props) } }
  end

  test "a referral slug must be one of config/referrals.yml" do
    assert_equal({ "slug" => "haven" }, Analytics::Events.clean(:referral_link_hit, slug: "haven"))
  end

  test "there is no property that could carry an IP address, a user agent or a typed answer" do
    properties = Analytics::Events.definitions.values.flat_map(&:keys).map(&:to_s).uniq
    properties.each { |prop| assert_no_match(/\b(ip|ua)\b|user_agent|referrer|url|path|query|email|name|slack|hca|address|text|comment|idea\b/, prop) unless %w[has_idea has_comment].include?(prop) }
  end
end
