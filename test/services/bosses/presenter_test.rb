require "test_helper"
require_relative "../../support/bosses_helper"
require_relative "../../support/ship_images_helper"
require_relative "../../support/fighters_helper"

class Bosses::PresenterTest < ActiveSupport::TestCase
  include BossesHelper
  include ShipImagesHelper
  include FightersHelper

  MONDAY = Date.new(2026, 11, 16)

  setup do
    @user = users(:onboarded)
    @other = users(:new_user)
    @boss = make_boss(name: "Boss 1")
  end

  # The clock reads midday UTC on `today`, so the last 24 hours before it are what the fighters are counted over.
  def present(today: MONDAY, user: @user, now: Time.utc(today.year, today.month, today.day, 12)) = Bosses::Presenter.new(user: user, today: today, now: now)

  test "no boss before the first one, with the arrival date" do
    presenter = present(today: FRIDAY - 2)
    assert_equal :none, presenter.state
    assert_not presenter.boss?
    assert_nil presenter.boss_name
    assert_nil presenter.art_path
    assert_equal FRIDAY, presenter.upcoming_on
    assert_equal "The next boss arrives Friday 13 November.", presenter.upcoming_text
    assert_equal "No boss right now.", presenter.summary
    assert_equal 0, presenter.remaining_seconds
    assert_nil presenter.contributed_text
  end

  test "no boss after the last one has been gone for more than the afterglow" do
    assert_equal :none, present(today: THURSDAY + 9).state
    assert_nil present(today: THURSDAY + 9).upcoming_text
  end

  test "in progress: bar, hours to go truncated, days left and end day" do
    ship_damage(@other, (310 * HOUR), on: FRIDAY)
    presenter = present

    assert_equal :in_progress, presenter.state
    assert_equal "Boss 1", presenter.boss_name
    assert_equal "bosses/placeholder.webp", presenter.art_path
    assert_predicate presenter.art_alt, :present?
    assert_equal 62, presenter.damage_percent
    assert_equal 38, presenter.health_percent
    assert_in_delta 0.62, presenter.damage_ratio, 0.0001
    assert_in_delta 0.38, presenter.health_ratio, 0.0001
    assert_equal 190 * HOUR, presenter.remaining_seconds
    assert_equal "about 190 hours to go", presenter.hours_to_go_text
    assert_equal 4, presenter.days_left
    assert_equal THURSDAY, presenter.ends_on
    assert_equal "Thursday", presenter.end_day_name
    assert_equal "Boss at 38% health, about 190 hours to go. Ends Thursday.", presenter.summary
    assert_equal "4 days left, ends Thursday", presenter.days_left_text
    assert_equal 0, presenter.overkill_seconds
    assert_not presenter.user_slayer?
  end

  test "a boss with its own picture shows it at its own size with its own alt text" do
    @boss.attach_art(ShipImages::Processor.call(upload_file(png_bytes(64, 32)), config: Bosses::ArtConfig.current))
    @boss.art_alt = "A boss with a very big hat"
    @boss.save!
    presenter = present

    assert_match(%r{\A/bosses/#{@boss.id}/art\?v=\h{12}\z}, presenter.art_path)
    assert_equal [ presenter.art_path, 64, 32 ], presenter.stage_art
    assert_equal "A boss with a very big hat", presenter.art_alt
  end

  test "a boss without a picture keeps the built-in cut-out and its alt text" do
    presenter = present
    assert_equal [ "design/boss-weekly.webp", 1000, 965 ], presenter.stage_art
    assert_equal Boss::ARTS.fetch("placeholder"), presenter.art_alt
  end

  test "a boss with neither a known built-in picture nor a picture of its own is described by its name" do
    @boss.update_columns(art_key: "retired")
    presenter = present
    assert_equal "The boss, Boss 1", presenter.art_alt
    assert_equal [ "bosses/retired.webp", 480, 376 ], presenter.stage_art
  end

  test "the presenter does not read the picture bytes" do
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] if payload[:sql].include?("art_content") }
    present.stage_art
    ActiveSupport::Notifications.unsubscribe(subscriber)
    assert_empty statements
  end

  test "hours to go are truncated, never rounded up" do
    ship_damage(@other, (310 * HOUR) - 3_599, on: FRIDAY)
    assert_equal "about 190 hours to go", present.hours_to_go_text, "190 h 59 m 59 s is still 190 hours"

    ship_damage(@other, 3_599 + 1, on: FRIDAY)
    assert_equal "about 189 hours to go", present.hours_to_go_text
  end

  test "an hour or less to go" do
    ship_damage(@other, (500 * HOUR) - 3_600, on: FRIDAY)
    assert_equal "about 1 hour to go", present.hours_to_go_text
    ship_damage(@other, 1, on: FRIDAY)
    assert_equal "less than an hour to go", present.hours_to_go_text
  end

  test "a bar that has barely moved still reads 100% health" do
    ship_damage(@other, 36, on: FRIDAY)
    assert_equal 100, present.health_percent
    assert_equal 0, present.damage_percent
    ship_damage(@other, HOUR, on: FRIDAY)
    assert_equal 100, present.health_percent, "1 hour of 500 is still 0%"
  end

  test "health text: full health before any hit, never 100% left once a hit lands, 1% left just short of the health" do
    assert_equal "Full health", present.health_text
    assert_equal "Boss at full health, no hits yet this week, about 500 hours to go. Ends Thursday.", present.summary

    ship_damage(@other, 1, on: FRIDAY)
    assert_equal "Under 1% damage", present.health_text
    assert_equal "Boss has taken under 1% damage, about 499 hours to go. Ends Thursday.", present.summary

    ship_damage(@other, (5 * HOUR) - 2, on: FRIDAY)
    assert_equal "Under 1% damage", present.health_text, "one second short of 1%"
    ship_damage(@other, 1, on: FRIDAY)
    assert_equal "99% left", present.health_text

    ship_damage(@other, (245 * HOUR), on: FRIDAY)
    assert_equal "50% left", present.health_text
    assert_equal "Boss at 50% health, about 250 hours to go. Ends Thursday.", present.summary

    ship_damage(@other, (250 * HOUR) - 1, on: FRIDAY)
    assert_equal "1% left", present.health_text, "one second short of the health is 99% damage, never 0% left"
    assert_equal :in_progress, present.state

    ship_damage(@other, 1, on: FRIDAY)
    assert_equal "0% left", present.health_text
    assert_equal :defeated, present.state
  end

  test "escaped summary words for no hits and for a scratch" do
    assert_equal "Boss escaped at full health, about 500 hours to go.", present(today: THURSDAY + 1).summary
    ship_damage(@other, 60, on: FRIDAY)
    assert_equal "Boss escaped after under 1% damage, about 499 hours to go.", present(today: THURSDAY + 1).summary
  end

  test "the last day says it ends today" do
    presenter = present(today: THURSDAY)
    assert_equal 1, presenter.days_left
    assert_equal "Last day, make it count", presenter.days_left_text
    assert_match(/Ends today\.\z/, presenter.summary)
  end

  test "defeated: celebration state, overkill shown, bar empty, kept for the rest of the week" do
    ship_damage(@other, (500 * HOUR) + (2 * HOUR) + (13 * 60), on: FRIDAY)
    presenter = present

    assert_equal :defeated, presenter.state
    assert_equal 100, presenter.damage_percent
    assert_equal 0, presenter.health_percent
    assert_equal 1.0, presenter.damage_ratio
    assert_equal 0, presenter.remaining_seconds
    assert_nil presenter.hours_to_go_text
    assert_equal 2 * HOUR + 13 * 60, presenter.overkill_seconds
    assert_equal "2 hours 13 minutes", presenter.overkill_text
    assert_equal "Boss defeated. Overkill: 2 hours 13 minutes.", presenter.summary
    assert_equal :defeated, present(today: THURSDAY).state
    assert_equal :defeated, present(today: THURSDAY + 3).state, "and for a few days after the week"
  end

  test "exact health: defeated, no overkill" do
    ship_damage(@other, 500 * HOUR, on: FRIDAY)
    presenter = present
    assert_equal :defeated, presenter.state
    assert_nil presenter.overkill_text
    assert_equal "Boss defeated.", presenter.summary
  end

  test "a recorded defeat stays defeated when a ship is later withdrawn and the damage drops" do
    big = ship_damage(@other, 600 * HOUR, on: FRIDAY)
    Bosses::CheckDefeat.call(@boss)
    assert @boss.reload.defeated?
    big.update!(status: "withdrawn")

    presenter = present
    assert_equal :defeated, presenter.state
    assert_equal 0, presenter.health_percent
    assert_equal 0, presenter.overkill_seconds
  end

  test "escaped: the week is over and the boss still stands, with no penalty" do
    ship_damage(@other, 100 * HOUR, on: FRIDAY)
    presenter = present(today: THURSDAY + 1)

    assert_equal :escaped, presenter.state
    assert_equal 0, presenter.days_left
    assert_nil presenter.days_left_text
    assert_equal "Boss escaped with 80% health left, about 400 hours to go.", presenter.summary
    assert_equal :escaped, present(today: THURSDAY + 7).state
    assert_equal :none, present(today: THURSDAY + 8).state
  end

  test "after an escape the next boss shows a gentle note for the first days only" do
    make_boss(starts_on: FRIDAY + 7, name: "Boss 2")
    assert_equal "Boss 1", present(today: FRIDAY + 7).previous_escaped_name
    assert_equal :in_progress, present(today: FRIDAY + 7).state
    assert_equal "Boss 2", present(today: FRIDAY + 7).boss_name
    assert_nil present(today: FRIDAY + 10).previous_escaped_name

    ship_damage(@other, 500 * HOUR, on: FRIDAY)
    assert_nil present(today: FRIDAY + 7).previous_escaped_name, "a boss that fell did not escape"
  end

  test "slayer needs at least 900 seconds on your own shipped ships in the boss week, while it is defeated" do
    ship_damage(@other, 500 * HOUR, on: FRIDAY)

    ship_damage(@user, 899, on: FRIDAY)
    assert_not present.user_slayer?
    assert present.slayer_still_possible?
    assert_not present(today: THURSDAY + 1).slayer_still_possible?, "the week is over"

    ship_damage(@user, 1, on: FRIDAY + 3)
    assert present.user_slayer?
    assert_not present.slayer_still_possible?
    assert present(today: THURSDAY + 2).user_slayer?, "the badge stays after the week"
  end

  test "coding that is not shipped is not a hit, and neither is a draft, a withdrawn or a rejected ship" do
    add_hours(@user, FRIDAY, 5 * HOUR)
    ship_damage(@user, 5_000, status: "draft")
    ship_damage(@user, 5_000, status: "withdrawn")
    ship_damage(@user, 5_000, status: "rejected")
    presenter = present

    assert_equal 0, presenter.contributed_seconds_this_week
    assert_equal "Ship a project to land your first hit.", presenter.contributed_text
    assert_equal "Full health", presenter.health_text
    assert_equal "Boss at full health, no hits yet this week, about 500 hours to go. Ends Thursday.", presenter.summary
  end

  test "an approved ship counts at its approved seconds, for the community and for you" do
    ship_damage(@user, 2 * HOUR, status: "approved", approved_seconds: HOUR)
    ship_damage(@other, 3 * HOUR)
    presenter = present

    assert_equal HOUR, presenter.contributed_seconds_this_week
    assert_equal "You've dealt 1 hour of damage this week.", presenter.contributed_text
    assert_equal "about 496 hours to go", presenter.hours_to_go_text, "1 hour approved plus 3 hours submitted"
  end

  test "a ship submitted in another boss week is not this week's contribution" do
    ship_damage(@user, 5_000, on: FRIDAY - 1)
    ship_damage(@user, 5_000, on: THURSDAY + 1)
    assert_equal 0, present.contributed_seconds_this_week
  end

  test "slayer counts only the boss week, and only when the boss fell" do
    ship_damage(@user, 5_000, on: FRIDAY - 1)
    ship_damage(@user, 5_000, on: THURSDAY + 1)
    ship_damage(@other, 500 * HOUR, on: FRIDAY)
    assert_not present.user_slayer?

    ship_damage(@user, 5_000, on: FRIDAY)
    assert present.user_slayer?

    other_boss = make_boss(starts_on: FRIDAY + 7)
    ship_damage(@user, 5_000, on: FRIDAY + 7)
    assert_equal :in_progress, present(today: FRIDAY + 7).state
    assert_not present(today: FRIDAY + 7).user_slayer?, "a standing boss gives no badge (#{other_boss.name})"
  end

  test "own contribution is the current user's alone" do
    ship_damage(@user, 90 * 60, on: FRIDAY)
    ship_damage(@user, 5 * 60, on: FRIDAY + 2)
    ship_damage(@other, 40 * HOUR, on: FRIDAY)

    assert_equal 95 * 60, present.contributed_seconds_this_week
    assert_equal "You've dealt 1 hour 35 minutes of damage this week.", present.contributed_text
    assert_equal 40 * HOUR, present(user: @other).contributed_seconds_this_week
  end

  test "nothing contributed yet invites the first hit" do
    assert_equal 0, present.contributed_seconds_this_week
    assert_equal "Ship a project to land your first hit.", present.contributed_text
  end

  test "an ended week talks in the past tense" do
    ship_damage(@user, 45 * 60, on: FRIDAY)
    assert_equal "You dealt 45 minutes of damage.", present(today: THURSDAY + 1).contributed_text
  end

  test "the community counts people with 15 minutes in the last 24 hours (not the UTC date), and only counts" do
    fighter("one", seconds: 900)
    fighter("short", seconds: 899)
    fighter("early", seconds: 3600, ago: 30.hours)
    assert_equal 1, present(today: NOW.to_date, now: NOW).fighter_count
    assert_equal "1 person coded in the last day.", present(today: NOW.to_date, now: NOW).community_text

    fighter("two", seconds: 3600)
    presenter = present(today: NOW.to_date, now: NOW)
    assert_equal 2, presenter.fighter_count
    assert_equal "2 people coded in the last day.", presenter.community_text
    assert_not presenter.quiet?
  end

  test "the community text says how many of them shipped, and nothing about shipping when none did" do
    shipper = fighter("shipper", seconds: 1800)
    fighter("other", seconds: 1800)
    assert_equal "2 people coded in the last day.", present(today: NOW.to_date, now: NOW).community_text

    ship_damage(shipper, 3600, on: NOW - 2.hours)
    presenter = present(today: NOW.to_date, now: NOW)
    assert_equal 1, presenter.shipper_count
    assert_equal "2 people coded in the last day. 1 of them shipped.", presenter.community_text
    assert_equal "2 people coded in the last day. 1 of them shipped. Ship a project to land your first hit.", presenter.arena_text, "the viewer shipped nothing themselves"
  end

  test "nobody coded: a quiet line, and the arena sentence leaves the headcount to it" do
    presenter = present(today: NOW.to_date, now: NOW)
    assert_predicate presenter, :quiet?
    assert_equal "Nobody has coded in the last day. Be the first to hit it.", presenter.community_text
    assert_equal "Nobody has coded in the last day. Be the first to hit it. Ship a project to land your first hit.", presenter.arena_text, "the empty arena is said in words, never drawn"
    assert_equal "Nobody has coded in the last day.", present(today: THURSDAY + 2).community_text, "no 'be the first to hit it' once the week is over"
  end

  test "the circles are the fighters, with the viewer's own marked" do
    fighter("other", seconds: 1800, name: "Ada")
    code_ago(@user, 3600)
    presenter = present(today: NOW.to_date, now: NOW)

    assert_equal 2, presenter.fighters.size
    assert_equal [ true ], presenter.fighters.select(&:you).map(&:you)
    assert_equal "Ada", presenter.fighters.find { |circle| !circle.you }.name
    assert_equal Bosses::Fighters.key_for(@user.id, @boss), presenter.fighters.find(&:you).key
  end

  test "the live payload carries the public bits, the health and the sentences, and nothing that names anyone" do
    ada = fighter("ada", seconds: 7200, name: "Ada")
    ship_damage(ada, 3600, on: NOW - 2.hours)
    closed = fighter("closed", seconds: 1800)
    payload = present(today: NOW.to_date, now: NOW).live_payload

    assert_equal %i[state boss_name health_percent health_text summary damage_text arena_text total shippers fighters].sort, payload.keys.sort
    assert_equal [ :in_progress, "Boss 1", 100, 2, 1 ], [ payload[:state].to_sym, payload[:boss_name], payload[:health_percent], payload[:total], payload[:shippers] ]
    assert_equal %i[key name title initial tone size tier path avatar_url you label detail status hint motion].sort, payload[:fighters].first.keys.sort
    named, other = payload[:fighters]
    assert_equal [ "Ada", "Ada", "A", "ship", "/players/#{ada.public_slug}", 4 ], named.values_at(:name, :title, :initial, :tier, :path, :size)
    handle = PublicProfile.handle_for(closed.public_slug)
    assert_equal [ handle, handle.first, "/players/#{closed.public_slug}" ], other.values_at(:name, :initial, :path), "everybody has a name and a link"
    text = payload.to_json
    [ "private.example.org", "Real Name", "ident!", "SLK", "\"#{ada.id}\"", ada.email, ada.slack_id, ada.hca_uid ].each { |secret| assert_not_includes text, secret }
    assert_not_includes text, "\"#{ada.public_slug}\"", "the address is only inside the link, never a field of its own"
  end

  test "people who coded are counted, but coding does not hurt the boss" do
    fighter("coder", seconds: 900)
    presenter = present(today: NOW.to_date, now: NOW)
    assert_equal 1, presenter.fighter_count
    assert_equal "Full health", presenter.health_text
    assert_equal 0, presenter.damage_percent
  end

  test "no names leak: the card text carries only counts and the viewer's own total" do
    @other.update!(display_name: "Zebulon Quasar")
    ship_damage(@other, 40 * HOUR)
    presenter = present
    texts = [ presenter.summary, presenter.health_text, presenter.community_text, presenter.contributed_text, presenter.hours_to_go_text ].join(" ")
    assert_not_includes texts, "Zebulon"
    assert_not_includes texts, "40 hours", "another person's own total is never shown"
    assert_equal 0, presenter.contributed_seconds_this_week
  end

  test "the default today is the UTC date, whatever the user's zone" do
    @user.update!(time_zone: "Pacific Time (US & Canada)")
    travel_to Time.utc(2026, 11, 16, 12) do
      assert_equal :in_progress, Bosses::Presenter.new(user: @user).state
    end
    travel_to Time.utc(2026, 11, 12, 12) do
      assert_equal :none, Bosses::Presenter.new(user: @user).state
    end
  end

  test "a ship shortly before the user's local midnight hits the boss their card shows" do
    # Thursday 19 Nov 17:00 in UTC-8 is Friday 20 Nov 01:00 UTC: the shipper's card and the damage agree on the next boss.
    @user.update!(time_zone: "Pacific Time (US & Canada)")
    next_boss = make_boss(starts_on: FRIDAY + 7, hp_seconds: 100 * HOUR)
    at = Time.utc(2026, 11, 20, 1)
    ship_damage(@user, 3 * HOUR, on: at)

    travel_to at do
      card = Bosses::Presenter.new(user: @user)
      assert_equal next_boss.name, card.boss_name
      assert_equal 3 * HOUR, card.contributed_seconds_this_week
      assert_equal 0, Bosses::Presenter.new(user: @user, today: THURSDAY).contributed_seconds_this_week
    end
  end

  test "human_duration" do
    assert_equal "less than a minute", Bosses::Presenter.human_duration(59)
    assert_equal "1 minute", Bosses::Presenter.human_duration(60)
    assert_equal "1 hour", Bosses::Presenter.human_duration(3_600)
    assert_equal "3 hours 1 minute", Bosses::Presenter.human_duration(3 * 3_600 + 61)
  end

  test "preview builds every state without touching the database" do
    %i[in_progress defeated escaped none].each do |state|
      presenter = Bosses::Presenter.preview(state: state, health_percent: 62, today: MONDAY)
      assert_equal state, presenter.state, state.to_s
    end
    assert_equal 62, Bosses::Presenter.preview(state: :in_progress, health_percent: 62, today: MONDAY).health_percent
    assert_equal 100, Bosses::Presenter.preview(state: :in_progress, health_percent: 100, today: MONDAY).health_percent
    assert_equal :defeated, Bosses::Presenter.preview(state: :in_progress, health_percent: 0, today: MONDAY).state
    assert_equal 1, Boss.count, "preview wrote nothing"
  end
end
