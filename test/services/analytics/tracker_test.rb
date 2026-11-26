require "test_helper"

class AnalyticsTrackerTest < ActiveSupport::TestCase
  setup do
    @user = users(:onboarded)
    @original_admins = ENV["ADMIN_HCA_UIDS"]
    @original_listed = ENV["ANALYTICS_EXCLUDE_HCA_UIDS"]
    @original_disabled = ENV["ANALYTICS_DISABLED"]
  end

  teardown do
    { "ADMIN_HCA_UIDS" => @original_admins, "ANALYTICS_EXCLUDE_HCA_UIDS" => @original_listed, "ANALYTICS_DISABLED" => @original_disabled }.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end

  def production_mode(&block) = stub_method(Analytics, :strict?, -> { false }, &block)

  def capture_log
    io = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    yield
    io.string
  ensure
    Rails.logger = original
  end

  test "records the event with its properties, the person and the time, and returns nil" do
    assert_nil Analytics.track(:ship_approved, user: @user, hours_bucket: "2-5", nth: "1", waited: "1d")

    event = AnalyticsEvent.last
    assert_equal "ship_approved", event.name
    assert_equal({ "hours_bucket" => "2-5", "nth" => "1", "waited" => "1d" }, event.props)
    assert_equal @user.id, event.user_id
    assert_nil event.visit_id
    assert_in_delta Time.current, event.occurred_at, 5
    assert_tracked :ship_approved, nth: "1"
  end

  test "an unknown event or property raises outside production, so a typo fails the suite" do
    assert_raises(Analytics::Events::Invalid) { Analytics.track(:ship_aproved, user: @user) }
    assert_raises(Analytics::Events::Invalid) { Analytics.track(:ship_approved, user: @user, email: "a@b.c") }
    assert_raises(Analytics::Events::Invalid) { Analytics.track(:ship_approved, user: @user, nth: "9") }
    assert_equal 0, AnalyticsEvent.count
  end

  test "in production the event is dropped and only its name is logged, never an error and never its properties" do
    log = capture_log do
      production_mode do
        assert_nil Analytics.track(:ship_aproved, user: @user, note: "PROBE-TEXT")
        assert_nil Analytics.track(:ship_approved, user: @user, nth: "PROBE-VALUE")
      end
    end

    assert_equal 0, AnalyticsEvent.count
    assert_includes log, "ship_aproved"
    assert_no_match(/PROBE/, log)
  end

  test "in production a database failure is swallowed and logged by class name only" do
    log = capture_log do
      production_mode do
        stub_method(AnalyticsEvent, :insert_all!, ->(*) { raise ActiveRecord::StatementInvalid, "PROBE-SQL-DETAIL" }) do
          assert_nil Analytics.track(:landing_viewed, user: @user)
        end
      end
    end

    assert_includes log, "ActiveRecord::StatementInvalid"
    assert_no_match(/PROBE/, log)
  end

  test "records nothing for staff, simulated players and the listed test players, whatever the stored flag says" do
    ENV["ADMIN_HCA_UIDS"] = users(:onboarded).hca_uid
    ENV["ANALYTICS_EXCLUDE_HCA_UIDS"] = " ident!tester , other "
    tester = User.create!(hca_uid: "ident!tester")
    sim = User.create!(hca_uid: "sim!42")
    [ users(:onboarded), tester, sim ].each { |excluded| Analytics.track(:signed_in, user: excluded) }
    assert_equal 0, AnalyticsEvent.count

    ENV.delete("ADMIN_HCA_UIDS")
    ENV.delete("ANALYTICS_EXCLUDE_HCA_UIDS")
    Analytics.track(:signed_in, user: tester)
    assert_equal 0, AnalyticsEvent.count, "a player flagged as excluded stays excluded until the flag is refreshed"
    tester.update!(analytics_excluded: false) # (a save refreshes the flag from the lists: no longer listed)
    assert_not tester.analytics_excluded?
    Analytics.track(:signed_in, user: tester)
    assert_equal 1, AnalyticsEvent.count
  end

  test "the stored flag is set on save from the lists, and a person is measured again when they leave them" do
    ENV["ANALYTICS_EXCLUDE_HCA_UIDS"] = "ident!new"
    user = users(:new_user)
    user.save!
    assert user.reload.analytics_excluded?
    assert_not_includes User.analytics_included, user

    ENV.delete("ANALYTICS_EXCLUDE_HCA_UIDS")
    user.save!
    assert_not user.reload.analytics_excluded?
    assert_includes User.analytics_included, user
    assert User.create!(hca_uid: "sim!7").analytics_excluded?
  end

  test "the kill switch flag stops all writes, and ANALYTICS_DISABLED does too" do
    with_feature(:analytics_paused) { Analytics.track(:signed_in, user: @user) }
    assert_equal 0, AnalyticsEvent.count

    ENV["ANALYTICS_DISABLED"] = "true"
    Analytics.track(:signed_in, user: @user)
    assert_equal 0, AnalyticsEvent.count

    ENV.delete("ANALYTICS_DISABLED")
    Analytics.track(:signed_in, user: @user)
    assert_equal 1, AnalyticsEvent.count
  end

  test "the kill switch is a registered flag that ships off" do
    assert_includes Features::NAMES, :analytics_paused
    assert_not Features.enabled?(:analytics_paused)
    assert_not Analytics.paused?
  end

  test "the visit is only looked up when the event is going to be written" do
    looked_up = 0
    visit = -> { looked_up += 1; nil }
    with_feature(:analytics_paused) { Analytics.track(:signed_in, user: @user, visit: visit) }
    assert_equal 0, looked_up
    Analytics.track(:signed_in, user: @user, visit: visit)
    assert_equal 1, looked_up
  end

  test "once: makes a repeat a no-op for that person, and is per person and per key" do
    3.times { Analytics.track(:quick_day_reached, user: @user, once: "quick:2026-11-10") }
    assert_equal 1, AnalyticsEvent.where(name: "quick_day_reached").count

    Analytics.track(:quick_day_reached, user: @user, once: "quick:2026-11-11")
    Analytics.track(:quick_day_reached, user: users(:new_user), once: "quick:2026-11-10")
    assert_equal 3, AnalyticsEvent.where(name: "quick_day_reached").count
  end

  test "once: needs a person and a key of 1 to 60 characters" do
    assert_raises(Analytics::Events::Invalid) { Analytics.track(:quick_day_reached, once: "k") }
    assert_raises(Analytics::Events::Invalid) { Analytics.track(:quick_day_reached, user: @user, once: "k" * 61) }
    assert_raises(Analytics::Events::Invalid) { Analytics.track(:quick_day_reached, user: @user, once: "") }
  end

  test "an event with neither a person nor a visit is dropped" do
    Analytics.track(:landing_viewed)
    assert_equal 0, AnalyticsEvent.count
  end

  test "an event of a visit with no person yet belongs to the visit alone" do
    visit = AnalyticsVisit.create!(visit_key: SecureRandom.urlsafe_base64(16), started_at: Time.current)
    Analytics.track(:landing_viewed, visit: visit)

    event = AnalyticsEvent.last
    assert_equal visit.id, event.visit_id
    assert_nil event.user_id
  end

  test "a visit that belongs to someone else is not attached to this person's event" do
    visit = AnalyticsVisit.create!(visit_key: SecureRandom.urlsafe_base64(16), started_at: Time.current, user: users(:new_user))
    Analytics.track(:signed_in, user: @user, visit: visit)

    event = AnalyticsEvent.last
    assert_nil event.visit_id
    assert_equal @user.id, event.user_id
  end

  test "inside a transaction the event is written when it commits and never when it rolls back" do
    ActiveRecord::Base.transaction do
      Analytics.track(:signed_in, user: @user)
      raise ActiveRecord::Rollback
    end
    assert_equal 0, AnalyticsEvent.count

    ActiveRecord::Base.transaction { Analytics.track(:signed_in, user: @user) }
    assert_equal 1, AnalyticsEvent.count
  end

  test "one event is one insert" do
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] if payload[:sql].match?(/analytics_/) && payload[:name] != "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { Analytics.track(:signed_in, user: @user) }
    assert_equal 1, queries.size, queries.inspect
  end

  test "presence is recorded once per person per local day, by the person's own time zone" do
    @user.update_columns(time_zone: "Pacific/Auckland")
    travel_to Time.utc(2026, 11, 26, 23, 0) do # already the 27th in Auckland
      3.times { AnalyticsSiteDay.touch(@user) }
    end
    assert_equal [ Date.new(2026, 11, 27) ], AnalyticsSiteDay.where(user: @user).pluck(:day)

    travel_to Time.utc(2026, 11, 28, 1, 0) do
      AnalyticsSiteDay.touch(@user)
      AnalyticsSiteDay.touch(users(:new_user)) # no time zone: UTC
    end
    assert_equal 2, AnalyticsSiteDay.where(user: @user).count
    assert_equal [ Date.new(2026, 11, 28) ], AnalyticsSiteDay.where(user: users(:new_user)).pluck(:day)
  end

  test "refresh_all! marks the listed people, clears the ones no longer listed and deletes what was recorded about them" do
    ENV["ANALYTICS_EXCLUDE_HCA_UIDS"] = users(:new_user).hca_uid
    visit = AnalyticsVisit.create!(visit_key: SecureRandom.urlsafe_base64(16), started_at: Time.current, user: users(:new_user))
    AnalyticsEvent.create!(name: "landing_viewed", visit: visit, user: users(:new_user), occurred_at: Time.current)
    AnalyticsSiteDay.create!(user: users(:new_user), day: Date.new(2026, 11, 9))
    Analytics.track(:signed_in, user: @user)

    assert_equal({ excluded: 1, marked: 1, cleared: 0 }, Analytics::Exclusion.refresh_all!)

    assert_equal [ @user.id ], AnalyticsEvent.pluck(:user_id)
    assert_equal 0, AnalyticsVisit.count + AnalyticsSiteDay.count
    assert users(:new_user).reload.analytics_excluded?
    ENV.delete("ANALYTICS_EXCLUDE_HCA_UIDS")
    assert_equal({ excluded: 0, marked: 0, cleared: 1 }, Analytics::Exclusion.refresh_all!)
  end
end
