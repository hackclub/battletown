require "test_helper"
require_relative "../../support/notifications_helper"
require_relative "../../support/ships_test_support"

# Who is due the survey DM and for which prompt window: active window, cooldowns, the unanswered cap and its reset, and
# time zones / local day boundaries.
class Nps::EligibilityTest < ActiveSupport::TestCase
  include NotificationsHelper
  include ShipsTestSupport

  NOW = Time.utc(2026, 11, 12, 12)
  TODAY = Date.new(2026, 11, 12)
  CONFIG = Nps::Config.current

  setup do
    @user = create_user
    code(@user, TODAY - 1, 20.minutes.to_i)
  end

  def verdict(user = @user, now: NOW) = Nps::Eligibility.check(user, now: now, config: CONFIG)

  def prompt(date, user: @user, status: "sent", key: Nps::Eligibility.key(user, date))
    at = Time.utc(date.year, date.month, date.day, 12)
    Notification.create!(user: user, kind: "nps_prompt", status: status, scheduled_for: at, due_at: at, subject_id: Nps::Eligibility.subject_id(date),
                         idempotency_key: key)
  end

  def answer(date, user: @user, at: nil)
    NpsResponse.create!(user: user, score: 8, answered_at: at || Time.utc(date.year, date.month, date.day, 13), prompt_window_date: date)
  end

  test "an active, onboarded person with a Slack id is eligible, for the window of their local today" do
    result = verdict
    assert result.eligible?
    assert_equal TODAY, result.window_date
    assert_equal 20261112, Nps::Eligibility.subject_id(result.window_date)
    assert_equal TODAY, Nps::Eligibility.window_date(20261112)
    assert_nil Nps::Eligibility.window_date(20269999)
    assert_nil Nps::Eligibility.window_date(nil)
  end

  test "someone who is not onboarded or has no Slack id is never eligible" do
    assert_equal :not_reachable, verdict(create_user(onboarded_at: nil)).reason
    assert_equal :not_reachable, verdict(create_user(slack_id: nil)).reason
    assert_equal :not_reachable, verdict(create_user(slack_id: "")).reason
  end

  test "active means at least 15 counted minutes on at least one of the last 7 local days, today included" do
    quiet = create_user
    code(quiet, TODAY - 1, 14.minutes.to_i + 59)
    assert_equal :not_active, verdict(quiet).reason

    code(quiet, TODAY - 1, 1) # exactly 15 minutes now
    assert verdict(quiet).eligible?

    edge = create_user
    code(edge, TODAY - 6, 15.minutes.to_i) # the 7th local day back counting today
    assert verdict(edge).eligible?
    old = create_user
    code(old, TODAY - 7, 3600)
    assert_equal :not_active, verdict(old).reason
    today_only = create_user
    code(today_only, TODAY, 900)
    assert verdict(today_only).eligible?
  end

  test "several small days do not add up: one day must reach the threshold" do
    spread = create_user
    3.times { |i| code(spread, TODAY - i, 8.minutes.to_i) }
    assert_equal :not_active, verdict(spread).reason
  end

  test "time before the person signed up does not count" do
    newcomer = create_user(created_at: Time.utc(2026, 11, 11, 12))
    code(newcomer, Date.new(2026, 11, 5), 3600)
    assert_equal :not_active, verdict(newcomer).reason
  end

  test "the window, the active days and the answer cooldown follow the person's own local date" do
    # 2026-11-12 03:00 UTC is still the 11th in Los Angeles and already the 12th in UTC.
    now = Time.utc(2026, 11, 12, 3)
    la = create_user(time_zone: "Pacific Time (US & Canada)")
    code(la, Date.new(2026, 11, 4), 3600) # 7 local days back from the 11th is the 5th: too old
    assert_equal :not_active, verdict(la, now: now).reason
    code(la, Date.new(2026, 11, 5), 900)
    result = verdict(la, now: now)
    assert result.eligible?
    assert_equal Date.new(2026, 11, 11), result.window_date

    utc = create_user
    code(utc, Date.new(2026, 11, 5), 900) # 7 UTC days back from the 12th is the 6th
    assert_equal :not_active, verdict(utc, now: now).reason
  end

  test "an answer starts a cooldown of nps.cooldown_days_after_answer local days" do
    answer(TODAY - 13)
    assert_equal :cooldown, verdict.reason
    answer(TODAY - 14, at: Time.utc(2026, 10, 29, 23, 59))
    NpsResponse.where(prompt_window_date: TODAY - 13).delete_all
    assert verdict.eligible?, "14 local days after the answer the cooldown is over"
  end

  test "the cooldown counts the local day of the answer, not 24-hour blocks" do
    # 06:00 UTC on the 29th is 23:00 on the 28th in Los Angeles, so their fourteen local days are over on the 11th.
    answered_at = Time.utc(2026, 10, 29, 6)
    la = create_user(time_zone: "Pacific Time (US & Canada)")
    utc = create_user
    [ la, utc ].each do |person|
      code(person, Date.new(2026, 11, 10), 1200)
      NpsResponse.create!(user: person, score: 8, answered_at: answered_at, prompt_window_date: Date.new(2026, 10, 28))
    end
    now = Time.utc(2026, 11, 11, 20) # the 11th in both zones
    assert verdict(la, now: now).eligible?
    assert_equal :cooldown, verdict(utc, now: now).reason
  end

  test "a person asked within the last nps.interval_days days is not asked again, then is" do
    prompt(TODAY - 1)
    assert_equal :recently_asked, verdict.reason
    NpsResponse.delete_all
    Notification.delete_all
    prompt(TODAY - 2)
    assert verdict.eligible?
  end

  test "a cancelled or failed prompt never reached them, so it does not count as asked" do
    prompt(TODAY - 1, status: "cancelled")
    prompt(TODAY - 1 - 5, status: "failed")
    assert verdict.eligible?
    prompt(TODAY - 1, status: "skipped", key: "other")
    assert_equal :recently_asked, verdict.reason
  end

  test "after max_prompts_without_answer unanswered prompts in a row they are not asked again" do
    [ 10, 8, 6 ].each { |back| prompt(TODAY - back) }
    code(@user, TODAY - 9, 900)
    assert_equal :too_many_unanswered, verdict.reason
  end

  test "two unanswered prompts are still fine" do
    [ 10, 8 ].each { |back| prompt(TODAY - back) }
    assert verdict.eligible?
  end

  test "answering restarts the count" do
    [ 20, 18, 16 ].each { |back| prompt(TODAY - back) }
    code(@user, TODAY - 17, 900)
    code(@user, TODAY - 10, 900)
    assert_equal :too_many_unanswered, verdict.reason
    answer(TODAY - 16, at: Time.utc(2026, 10, 27, 12)) # answered the last one; its cooldown has passed by now
    assert verdict.eligible?
  end

  test "coming back after an idle stretch restarts the count, staying active does not" do
    [ 40, 38, 36 ].each { |back| prompt(TODAY - back) }
    code(@user, TODAY - 37, 900)
    code(@user, TODAY - 35, 900)
    # Active on every stretch since: no gap longer than nps.idle_days_reset days.
    (1..34).step(7).each { |back| code(@user, TODAY - back, 900) }
    assert_equal :too_many_unanswered, verdict.reason

    returned = create_user
    [ 40, 38, 36 ].each { |back| prompt(TODAY - back, user: returned) }
    code(returned, TODAY - 35, 900)
    code(returned, TODAY - 2, 900) # nothing for 33 days, then back
    assert verdict(returned).eligible?, "idle for more than #{CONFIG.idle_days_reset} days, then active again"
  end

  test "after coming back they can be asked up to the cap again, then stop again" do
    [ 40, 38, 36 ].each { |back| prompt(TODAY - back) }
    code(@user, TODAY - 35, 900)
    code(@user, TODAY - 9, 900) # back after more than two weeks away
    [ 8, 6 ].each { |back| prompt(TODAY - back) }
    assert verdict.eligible?, "two since returning"
    prompt(TODAY - 4)
    assert_equal :too_many_unanswered, verdict.reason
  end

  test "the key is per person per window and the same for a repeat" do
    assert_equal "nps_prompt:#{@user.id}:2026-11-12", Nps::Eligibility.key(@user, TODAY)
  end
end
