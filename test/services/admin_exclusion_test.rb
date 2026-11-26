require "test_helper"

# Staff (ADMIN_HCA_UIDS), simulated players (hca_uid "sim!...") and the testers in ANALYTICS_EXCLUDE_HCA_UIDS are not counted by the
# existing staff metrics: AdminMetrics, AdminStats, ReturningMetrics, Nps::Stats and Notifications::Email::Stats (plans/analytics.md, WP7).
class AdminExclusionTest < ActiveSupport::TestCase
  TODAY = Date.new(2026, 11, 12) # a Thursday
  NOW = Time.utc(2026, 11, 12, 15)

  setup do
    @original = ENV.values_at("ADMIN_HCA_UIDS", "ANALYTICS_EXCLUDE_HCA_UIDS")
    ENV.delete("ADMIN_HCA_UIDS")
    ENV.delete("ANALYTICS_EXCLUDE_HCA_UIDS")
    populate(users(:onboarded), "normal")
  end

  teardown do
    ENV["ADMIN_HCA_UIDS"], ENV["ANALYTICS_EXCLUDE_HCA_UIDS"] = @original
    ENV.delete("ADMIN_HCA_UIDS") if @original.first.nil?
    ENV.delete("ANALYTICS_EXCLUDE_HCA_UIDS") if @original.last.nil?
  end

  # Everything the five services read, for one person.
  def populate(user, key)
    user.update_columns(onboarded_at: NOW, onboarding_step: 6, prize_key: Prize.paid.first.key, project_kind: "game", referral_source: "other")
    HourEntry.create!(user: user, local_date: TODAY, seconds: 3600, source: "manual", note: "test", idempotency_key: "excl-#{key}")
    WelcomeBackWindow.create!(user: user, starts_on: TODAY, ends_on: TODAY + 2, idle_days: 7)
    Notification.create!(user: user, kind: "returning_nudge", channel: "email", status: "sent", scheduled_for: NOW, due_at: NOW, sent_at: NOW, created_at: NOW, subject_id: 1,
                         idempotency_key: "excl-nudge-#{key}")
    NpsResponse.create!(user: user, score: 3, answered_at: NOW, prompt_window_date: TODAY)
  end

  def person(uid, key) = User.create!(hca_uid: uid, created_at: Time.utc(2026, 1, 1)).tap { |user| populate(user, key) }

  def readings
    metrics = AdminMetrics.call(today: TODAY)
    {
      daily: metrics.daily, weekly: metrics.weekly, funnel: metrics.funnel, dropout: metrics.dropout,
      stats: AdminStats.call(today: TODAY), returning: ReturningMetrics.call(today: TODAY),
      nps: [ Nps::Stats.overall, Nps::Stats.trend(now: NOW) ], email: Notifications::Email::Stats.weekly(today: TODAY)
    }
  end

  test "the baseline counts the normal person in every service" do
    seen = readings
    assert_equal 1, seen[:daily].find { |day| day.date == TODAY }.active_users
    assert_equal 1, seen[:funnel].find { |step| step.label == "First coded day" }.count
    assert_equal 1, seen[:stats].onboarded
    assert_equal 1, seen[:returning].windows_total
    assert_equal 1, seen[:returning].nudges_total
    assert_equal 1, seen[:nps].first.responses
    assert_equal 1, seen[:email].first.total
  end

  test "a simulated player with data moves no number" do
    before = readings
    person("sim!ada", "sim")
    assert_equal before, readings
  end

  test "a staff member with data moves no number" do
    before = readings
    ENV["ADMIN_HCA_UIDS"] = "ident!staff"
    person("ident!staff", "staff")
    assert_equal before, readings
  end

  test "a listed tester with data moves no number" do
    before = readings
    ENV["ANALYTICS_EXCLUDE_HCA_UIDS"] = "ident!friend, ident!other"
    person("ident!friend", "friend")
    assert_equal before, readings
  end

  test "a list change takes effect before the stored flag is refreshed" do
    before = readings
    tester = person("ident!late", "late")
    assert_not_equal before, readings
    ENV["ANALYTICS_EXCLUDE_HCA_UIDS"] = "ident!late"
    assert_not tester.reload.analytics_excluded?, "the stored flag is still stale"
    assert_equal before, readings
  end

  test "a normal person with the same data does move the numbers" do
    before = readings
    person("ident!real", "real")
    after = readings
    assert_equal 2, after[:daily].find { |day| day.date == TODAY }.active_users
    assert_equal before[:stats].total_users + 1, after[:stats].total_users
    assert_equal 2, after[:returning].windows_total
    assert_equal 2, after[:nps].first.responses
    assert_equal 2, after[:email].first.total
  end

  test "a uid with a quote or a colon in the list cannot break the queries" do
    ENV["ANALYTICS_EXCLUDE_HCA_UIDS"] = "it's:a_uid, x"
    assert_nothing_raised { readings }
    assert_equal 1, User.analytics_included.where(id: users(:onboarded)).count
  end
end
