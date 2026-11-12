require "test_helper"
require_relative "../../support/merch_helper"

class MerchTrack::ProgressTest < ActiveSupport::TestCase
  include MerchHelper

  setup do
    @user = build_user(created_on: Date.new(2026, 11, 1))
    @boss = make_boss
  end

  def progress(now: AFTER_WEEK, user: @user, boss: @boss, **changes) = MerchTrack::Progress.for(user, boss, now: now, config: config(**changes))

  def states(progress) = progress.days.map(&:state)

  test "exactly five goal days earn the week, four do not" do
    goal_days(@user, 4)
    assert_not progress.earned?
    assert_equal 4, progress.met
    assert_equal 1, progress.to_go
    goal_day(@user, WEEK_START + 4)
    assert progress.earned?
    assert_equal 5, progress.met
    assert_equal 0, progress.to_go
  end

  test "more than five also earns, and the days need not be consecutive" do
    [ 0, 2, 3, 5, 6 ].each { |offset| goal_day(@user, WEEK_START + offset) }
    assert progress.earned?
    goal_day(@user, WEEK_START + 1)
    assert_equal 6, progress.met
  end

  test "days_required comes from the config" do
    goal_days(@user, 3)
    assert progress(days_required: 3).earned?
    assert_not progress(days_required: 4).earned?
  end

  test "the week has seven local dates, first and last day included, and nothing outside it counts" do
    goal_day(@user, WEEK_START - 1)
    goal_day(@user, WEEK_END + 1)
    assert_equal 0, progress.met
    goal_day(@user, WEEK_START)
    goal_day(@user, WEEK_END)
    (1..5).each { |offset| goal_day(@user, WEEK_START + offset, met: false) }
    result = progress
    assert_equal 2, result.met
    assert_equal (WEEK_START..WEEK_END).to_a, result.days.map(&:date)
    assert_equal %i[met missed missed missed missed missed met], states(result)
  end

  test "days are the person's own local dates: the clock decides today and pending, the stored local date decides the rest" do
    auckland = build_user(time_zone: "Pacific/Auckland", created_on: Date.new(2026, 11, 1))
    goal_day(auckland, WEEK_START)
    # 20:00 UTC on Sunday 15 November is already Monday 16 November in Auckland (UTC+13).
    result = progress(user: auckland, now: Time.utc(2026, 11, 15, 20))
    today = result.days.find(&:today)
    assert_equal Date.new(2026, 11, 16), today.date
    assert_equal :pending, today.state
    assert_equal :future, result.days.last.state
    assert_equal :met, result.days.first.state
  end

  test "a boss week that crosses the autumn clock change is still seven dates and today flips at local midnight" do
    new_york = build_user(time_zone: "America/New_York", created_on: Date.new(2026, 10, 20))
    boss = make_boss(starts_on: Date.new(2026, 10, 30))
    first_day = progress(user: new_york, boss: boss, now: Time.utc(2026, 11, 2, 4, 59))
    assert_equal 7, first_day.days.size
    assert_equal Date.new(2026, 11, 1), first_day.days.find(&:today).date, "23:59 on the 25-hour day is still 1 November"
    assert_equal Date.new(2026, 11, 2), progress(user: new_york, boss: boss, now: Time.utc(2026, 11, 2, 5, 0)).days.find(&:today).date
    # Both 01:30s of the repeated hour are the same local date.
    [ Time.utc(2026, 11, 1, 5, 30), Time.utc(2026, 11, 1, 6, 30) ].each do |instant|
      assert_equal Date.new(2026, 11, 1), progress(user: new_york, boss: boss, now: instant).days.find(&:today).date
    end
  end

  test "dates before sign-up never count, even with a stray row" do
    late = build_user(created_on: Date.new(2026, 11, 15))
    (WEEK_START..Date.new(2026, 11, 17)).each { |date| goal_day(late, date) }
    (Date.new(2026, 11, 18)..WEEK_END).each { |date| goal_day(late, date, met: false) }
    result = progress(user: late)
    assert_equal %i[not_counted not_counted met met met missed missed], states(result)
    assert_equal 3, result.met
    assert_not result.earned?
  end

  test "a day still inside the grace period is pending, and it never counts until it settles" do
    goal_days(@user, 4)
    goal_day(@user, WEEK_START + 4, met: false)
    goal_day(@user, WEEK_START + 5, met: false)
    # Thursday 19 November ended at 00:00 on the 20th; its grace period runs until 06:00, so it has no row yet.
    during = progress(now: Time.utc(2026, 11, 20, 3))
    assert_equal :pending, during.days.last.state
    assert_equal 1, during.pending
    assert_equal 4, during.met
    assert_not during.earned?
    goal_day(@user, WEEK_END)
    assert progress(now: Time.utc(2026, 11, 20, 6)).earned?, "once it has settled as met, the fifth day counts"
  end

  test "pending shows for a closed day that has no settled row yet, and settling turns it into met or missed" do
    source = StubHoursSource.new((WEEK_START..WEEK_START + 5).to_h { |date| [ date, 3600 ] })
    now = Time.utc(2026, 11, 20, 3)
    Game::Settle.call(@user, through: now, source: source)
    result = progress(now: now)
    assert_equal :pending, result.days.last.state
    assert_equal 6, result.met
    assert result.earned?
    after = Time.utc(2026, 11, 20, 6)
    Game::Settle.call(@user, through: after, source: source)
    assert_equal :missed, progress(now: after).days.last.state
  end

  test "future days are future, and reachable? says whether the week can still be earned" do
    now = Time.utc(2026, 11, 17, 12)
    goal_days(@user, 1)
    (WEEK_START + 1..WEEK_START + 3).each { |date| goal_day(@user, date, met: false) }
    result = progress(now: now)
    assert_equal %i[met missed missed missed pending future future], states(result)
    assert_equal 3, result.open_days
    assert_not result.reachable?, "one met and three open days cannot reach five"
    assert progress(now: now, days_required: 4).reachable?
  end

  test "a day the freeze covered is not a goal day" do
    goal_days(@user, 4)
    goal_day(@user, WEEK_START + 4, frozen: true)
    result = progress
    assert_equal :missed, result.days[4].state
    assert_equal 4, result.met
    assert_not result.earned?
  end

  test "the item is the Nth boss week's item and nil past the end of the list" do
    assert_equal "week_1_sticker", progress.item.key
    second = make_boss(starts_on: WEEK_START + 7)
    assert_equal "week_2_item", progress(boss: second).item.key
    (2..4).each { |n| make_boss(starts_on: WEEK_START + 7 * n) }
    fifth = Boss.chronological.last
    assert_nil progress(boss: fifth).item
    assert_equal "week_4_item", progress(boss: fifth, after_last_week: "repeat_last").item.key
  end
end
