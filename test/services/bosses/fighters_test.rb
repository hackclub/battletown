require "test_helper"
require_relative "../../support/fighters_helper"

class Bosses::FightersTest < ActiveSupport::TestCase
  include FightersHelper

  setup { @boss = make_boss(starts_on: FRIDAY) }

  def circles(now: NOW) = fighters_at(@boss, now: now).circles

  # --- who counts: a rolling 24 hours ---

  test "recorded within the last 24 hours counts, a minute older does not" do
    inside = fighter("inside", seconds: 900, ago: 23.hours + 59.minutes)
    fighter("outside", seconds: 900, ago: 24.hours + 1.minute)

    snapshot = fighters_at(@boss)
    assert_equal 1, snapshot.total
    assert_equal [ Bosses::Fighters.key_for(inside.id, @boss) ], snapshot.circles.map(&:key)
  end

  test "it is the last 24 hours, not the UTC date: someone who coded at 23:00 yesterday is still a fighter just after midnight" do
    after_midnight = Time.utc(2026, 11, 18, 0, 30)
    late = fighter("late", seconds: 1800, ago: 90.minutes, now: after_midnight) # 23:00 on the 17th
    fighter("morning", seconds: 1800, ago: 23.hours, now: after_midnight)       # 01:30 on the 17th
    fighter("yesterday", seconds: 1800, ago: 25.hours, now: after_midnight)

    snapshot = fighters_at(@boss, now: after_midnight)
    assert_equal 2, snapshot.total
    assert_includes snapshot.circles.map(&:key), Bosses::Fighters.key_for(late.id, @boss)
  end

  test "under 15 minutes is not a fighter, exactly 15 is" do
    fighter("short", seconds: 899)
    fighter("exact", seconds: 900)

    assert_equal 1, fighters_at(@boss).total
  end

  test "a person is one circle however many projects and entries their minutes come from" do
    user = fighter("many", seconds: nil)
    code_ago(user, 400, project: "alpha")
    code_ago(user, 400, project: "beta")
    code_ago(user, 400, project: "alpha", ago: 2.hours)

    assert_equal 1, fighters_at(@boss).total
    assert_equal 1200 / 60, circles.first.minutes
  end

  test "an adjustment is an entry like any other: it can take someone under the mark" do
    user = fighter("adjusted", seconds: 1000)
    code_ago(user, -200, source: "adjustment")

    assert_equal 0, fighters_at(@boss).total
  end

  test "time on days before the person signed up does not count, time from the sign-up day on does" do
    user = fighter("cutoff", seconds: nil)
    user.update_columns(signed_up_on: Date.new(2026, 11, 18))
    code_ago(user, 1800, ago: 14.hours, date: Date.new(2026, 11, 17)) # recorded 22:00 yesterday, dated before sign-up
    assert_equal 0, fighters_at(@boss).total

    code_ago(user, 900, ago: 1.hour)
    assert_equal 1, fighters_at(@boss).total
    assert_equal 15, circles.first.minutes, "only the counted entry is summed"
  end

  test "time backfilled from an old day does not make someone a fighter" do
    user = fighter("backfill", seconds: nil)
    code_ago(user, 7200, ago: 1.hour, date: Date.new(2026, 11, 10))

    assert_equal 0, fighters_at(@boss).total
  end

  test "staff and everybody else count the same" do
    staff = fighter("staff", seconds: 1800)
    staff.update_columns(hca_uid: "ident!staff-admin")
    original = ENV["ADMIN_HCA_UIDS"]
    ENV["ADMIN_HCA_UIDS"] = "ident!staff-admin"
    fighter("plain", seconds: 1800)

    assert_equal 2, fighters_at(@boss).total
  ensure
    original.nil? ? ENV.delete("ADMIN_HCA_UIDS") : ENV["ADMIN_HCA_UIDS"] = original
  end

  # --- size and tier ---

  test "the size band comes from the minutes against the daily goal (60 minutes)" do
    goal = Game::Config.current.goal_seconds
    assert_equal 3600, goal
    {
      900 => 1, 1799 => 1, 1800 => 2, 3599 => 2, 3600 => 3, 7199 => 3, 7200 => 4, 14_399 => 4, 14_400 => 5, 40_000 => 5
    }.each { |seconds, size| assert_equal size, Bosses::Fighters.size_for(seconds), "#{seconds} seconds" }
  end

  test "the size follows a different daily goal" do
    assert_equal 5, Bosses::Fighters.size_for(1200, goal: 300)
    assert_equal 1, Bosses::Fighters.size_for(100, goal: 300)
  end

  test "tier: a shipper hits hard, someone at the daily goal hits lightly, the rest warm up" do
    shipper = fighter("shipper", seconds: 900)
    ship_damage(shipper, 3600, on: NOW - 2.hours)
    fighter("steady", seconds: 3600)
    fighter("warm", seconds: 3599)

    tiers = circles.to_h { |circle| [ circle.minutes, circle.tier ] }
    assert_equal({ 15 => :ship, 60 => :code, 59 => :idle }, tiers)
  end

  test "the size and tier are put on the circle" do
    user = fighter("big", seconds: 5 * 3600)
    circle = circles.first
    assert_equal [ 5, :code, 300 ], [ circle.size, circle.tier, circle.minutes ]
    assert_equal Bosses::Fighters.key_for(user.id, @boss), circle.key
  end

  # --- shippers ---

  test "a submitted or approved ship in this boss's week from the last 24 hours makes a shipper; nothing else does" do
    submitted = fighter("submitted", seconds: 1800)
    approved = fighter("approved", seconds: 1800)
    rejected = fighter("rejected", seconds: 1800)
    withdrawn = fighter("withdrawn", seconds: 1800)
    draft = fighter("draft", seconds: 1800)
    old = fighter("old", seconds: 1800)
    last_week = fighter("lastweek", seconds: 1800)
    ship_damage(submitted, 3600, on: NOW - 3.hours)
    ship_damage(approved, 3600, on: NOW - 3.hours, status: "approved")
    ship_damage(rejected, 3600, on: NOW - 3.hours, status: "rejected")
    ship_damage(withdrawn, 3600, on: NOW - 3.hours, status: "withdrawn")
    ship_damage(draft, 3600, on: NOW - 3.hours, status: "draft")
    ship_damage(old, 3600, on: NOW - 25.hours)
    ship_damage(last_week, 3600, on: FRIDAY.in_time_zone("UTC") - 1.hour)

    snapshot = fighters_at(@boss)
    assert_equal 7, snapshot.total
    assert_equal 2, snapshot.shippers
    assert_equal %i[ship ship], snapshot.circles.first(2).map(&:tier), "shippers come first"
  end

  test "someone who shipped but has not coded 15 minutes in the last day is not a fighter at all" do
    shipper = fighter("quietshipper", seconds: 600)
    ship_damage(shipper, 3600, on: NOW - 3.hours)

    assert_equal [ 0, 0 ], fighters_at(@boss).then { |snapshot| [ snapshot.total, snapshot.shippers ] }
  end

  test "with no boss nobody is a shipper" do
    shipper = fighter("noboss", seconds: 1800)
    ship_damage(shipper, 3600, on: NOW - 3.hours)

    snapshot = fighters_at(nil)
    assert_equal [ 1, 0 ], [ snapshot.total, snapshot.shippers ]
    assert_equal :idle, snapshot.circles.first.tier, "30 minutes is under the daily goal"
  end

  # --- order and limit ---

  test "shippers first, then the most coded; at most 12 are drawn but the counts are everybody's" do
    15.times { |index| fighter("p#{index}", seconds: 900 + (index * 60)) }
    small_shipper = fighter("smallshipper", seconds: 900)
    ship_damage(small_shipper, 3600, on: NOW - 3.hours)

    snapshot = fighters_at(@boss)
    assert_equal 12, snapshot.circles.size
    assert_equal 16, snapshot.total
    assert_equal 1, snapshot.shippers
    assert_equal :ship, snapshot.circles.first.tier
    assert_equal (19..29).to_a.reverse, snapshot.circles.drop(1).map(&:minutes), "then the most coded"
  end

  test "the whole thing is one query" do
    5.times { |index| fighter("q#{index}", seconds: 1800) }
    ship_damage(User.find_by(hca_uid: "ident!q0"), 3600, on: NOW - 1.hour)

    assert_equal 1, count_queries { Bosses::Fighters.call(@boss, now: NOW) }
  end

  # --- what is public ---

  test "every fighter shows a name, a profile link and an avatar colour: the chosen name, else the Slack name, else a generated handle" do
    chosen = fighter("chosen", seconds: 3600, name: "Ada")
    slacky = fighter("slacky", seconds: 3000)
    SlackProfile.create!(user: slacky, display_name: "Slacky")
    slack_off = fighter("slackoff", seconds: 2400)
    SlackProfile.create!(user: slack_off, display_name: "Hidden Slack", use_name: false, use_picture: false)
    plain = fighter("plain", seconds: 1800)

    by_slug = circles.index_by(&:slug)
    assert_equal 4, by_slug.size
    assert_equal "Ada", by_slug[chosen.public_slug].name
    assert_equal "/players/#{chosen.public_slug}", by_slug[chosen.public_slug].path
    assert_equal Profiles::Presenter.tone_for(chosen.public_slug), by_slug[chosen.public_slug].tone
    assert_equal "A", by_slug[chosen.public_slug].initial
    assert_equal "Slacky", by_slug[slacky.public_slug].name
    assert_equal PublicProfile.handle_for(slack_off.public_slug), by_slug[slack_off.public_slug].name
    assert_equal PublicProfile.handle_for(plain.public_slug), by_slug[plain.public_slug].name
    circles.each do |circle|
      assert_equal "/players/#{circle.slug}", circle.path
      assert_equal circle.name, circle.title
      assert_not_equal circle.slug, circle.key, "the animation key is not the address"
      assert_nil circle.avatar_url, "no picture stored"
    end
  end

  test "a circle's avatar is the version of the stored Slack picture, only when the player uses it" do
    with = fighter("withpic", seconds: 3600)
    SlackProfile.create!(user: with, picture: "bytes", picture_sha256: "b" * 64, picture_bytes: 5, status: "ok")
    off = fighter("offpic", seconds: 1800)
    SlackProfile.create!(user: off, use_picture: false, picture: "bytes", picture_sha256: "c" * 64, picture_bytes: 5, status: "ok")

    by_slug = circles.index_by(&:slug)
    assert_equal "/players/#{with.public_slug}/avatar?v=#{'b' * 10}", by_slug[with.public_slug].avatar_url
    assert_nil by_slug[off.public_slug].avatar_url
  end

  test "nothing that names a person is on a circle: no id, email, real name or Slack id" do
    user = fighter("secret", seconds: 1800, name: "Ada")
    fighter("secret2", seconds: 1800)

    text = circles.map(&:to_h).to_json
    [ user.id.to_s.then { |id| "\"#{id}\"" }, "private.example.org", "Real Name", "SLK", "ident!", user.hca_uid, user.slack_id, user.email ].each do |secret|
      assert_not_includes text, secret
    end
    assert_equal 12, circles.first.key.size
    assert_not_equal user.id.to_s, circles.first.key
  end

  test "the key is stable inside a boss week and different for another week and another person" do
    one = fighter("keyone", seconds: 1800)
    two = fighter("keytwo", seconds: 1800)
    next_week = make_boss(starts_on: FRIDAY + 7)

    assert_equal Bosses::Fighters.key_for(one.id, @boss), Bosses::Fighters.key_for(one.id, @boss)
    assert_not_equal Bosses::Fighters.key_for(one.id, @boss), Bosses::Fighters.key_for(two.id, @boss)
    assert_not_equal Bosses::Fighters.key_for(one.id, @boss), Bosses::Fighters.key_for(one.id, next_week)
  end

  test "the circle says it in words, and marks the viewer" do
    shipper = fighter("words", seconds: 7200, name: "Ada")
    ship_damage(shipper, 3600, on: NOW - 3.hours)
    circle = circles.first

    assert_equal "Ada", circle.title
    assert_equal "coded about 2 h in the last day", circle.detail
    assert_equal "shipped a project: hit the boss", circle.status
    assert_equal "Click to see their profile", circle.hint
    assert_equal "Ada: coded about 2 h in the last day, shipped a project: hit the boss. Click to see their profile.", circle.label

    mine = circle.for_viewer(circle.key)
    assert_predicate mine, :you
    assert_equal "You (Ada)", mine.title
    assert_equal "Click to see your profile", mine.hint
    assert_not circle.for_viewer("someoneelse").you
  end

  test "the words for the other tiers" do
    steady_user = fighter("steady", seconds: 3600 + 1200, name: "Stella")
    warm_user = fighter("warm", seconds: 1500, name: "Wes")
    steady, warm = circles

    assert_equal "Stella: coded about 1.5 h in the last day, hits it with a steady pace. Click to see their profile.", steady.label
    assert_equal "Wes: coded about 25 min in the last day, warming up. Click to see their profile.", warm.label
    assert_equal "/players/#{warm_user.public_slug}", warm.path
    assert_equal "You (Wes)", warm.for_viewer(warm.key).title
    assert_equal "/players/#{steady_user.public_slug}", steady.path
  end

  # --- the cache ---

  test "the shared part is cached for 20 seconds per boss and minute" do
    swap_cache do
      fighter("cached", seconds: 1800)
      assert_equal 1, fighters_at(@boss).total

      fighter("later", seconds: 1800)
      assert_equal 0, count_queries { assert_equal 1, fighters_at(@boss).total }, "a second look inside the window reads the cache"

      travel 21.seconds do
        assert_equal 2, fighters_at(@boss).total, "after 20 seconds it is read again"
      end
    end
  end

  test "another boss and another minute are other cache entries, and forget empties them" do
    swap_cache do
      fighter("one", seconds: 1800)
      assert_equal 1, fighters_at(@boss).total
      fighter("two", seconds: 1800)

      assert_equal 2, fighters_at(@boss, now: NOW + 1.minute).total, "the next minute is a new entry"
      assert_equal 2, fighters_at(nil).total, "so is another boss"
      assert_equal 1, fighters_at(@boss).total

      Bosses::Fighters.forget
      assert_equal 2, fighters_at(@boss).total
    end
  end

  def count_queries
    count = 0
    counter = ->(*, payload) { count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) || payload[:sql].match?(/\A\s*(BEGIN|COMMIT|SAVEPOINT|RELEASE)/i) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end
end
