require "test_helper"
require_relative "../../support/coins_helper"
require_relative "../../support/shop_helper"
require_relative "../../support/bosses_helper"
require_relative "../../support/ships_test_support"
require_relative "../../support/hackatime_helper"

class Dashboard::PresenterTest < ActiveSupport::TestCase
  include CoinsHelper
  include ShopTestHelper
  include BossesHelper
  include ShipsTestSupport
  include HackatimeHelper

  # A Saturday, midday UTC: the 14th is "today" for a UTC user, the 13th (a Friday) is the day before.
  NOW = Time.utc(2026, 11, 14, 12)
  TODAY = Date.new(2026, 11, 14)
  QUICK = 900

  setup do
    @user = build_user(created_on: TODAY - 30)
  end

  def present(user = @user, now: NOW)
    Game::Settle.call(user, through: now)
    Dashboard::Presenter.new(user: user, now: now)
  end

  # Quick-qualifying (15 minute) days, one per date from `first` to `last`.
  def code_days(first, last, seconds: QUICK)
    (first..last).each { |date| add_hours(@user, date, seconds) }
  end

  # --- header ---

  test "greets by display name with a fallback and gives the user's local date" do
    @user.update!(display_name: "Ada")
    assert_equal "Ada", present.name
    assert_equal "Saturday 14 November", present.date_text
    @user.update!(display_name: nil)
    assert_equal "adventurer", present.name
  end

  test "today is the user's local date, not the UTC date" do
    @user.update_columns(time_zone: "Pacific/Kiritimati")
    late = Time.utc(2026, 11, 14, 20)
    assert_equal Date.new(2026, 11, 15), present(now: late).today_date
  end

  # --- a brand-new user ---

  test "a brand-new user gets the first-run state, no streaks and a day one bonus" do
    d = present
    assert d.today.first_run
    assert_equal 0, d.today.minutes
    refute d.today.quick_met
    assert_equal "0 of 60 minutes", d.today.progress_text
    assert_equal "15 minutes to go for the 15-minute mark", d.today.quick_text
    assert_equal "Hit 15 minutes to start a streak: today's bonus is 5% once the day closes.", d.today.bonus_message
    assert_equal :empty, d.quick_streak.state
    assert_equal :empty, d.goal_streak.state
    assert_equal "Code for 15 minutes to start your streak.", d.quick_streak.message
    assert_equal "Freeze ready", d.quick_streak.freeze_text
    assert_nil d.quick_streak.best_text
  end

  test "first run ends once any hours exist" do
    add_hours(@user, TODAY, 60)
    refute present.today.first_run
  end

  # --- today ---

  test "minutes coded today against the daily goal, and the 15 minute mark" do
    add_hours(@user, TODAY, 1380)
    d = present
    assert_equal 23, d.today.minutes
    assert_equal 3600, d.today.progress_max
    assert_equal 1380, d.today.progress_value
    assert_equal "23 of 60 minutes", d.today.progress_text
    assert d.today.quick_met
    refute d.today.goal_met
    assert_equal "15-minute mark reached", d.today.quick_text
    assert_match(/on track for 5%, confirmed once the day closes/, d.today.bonus_message)
  end

  test "the progress value is capped at the goal and the goal is reported when met" do
    add_hours(@user, TODAY, 5000)
    d = present
    assert_equal 3600, d.today.progress_value
    assert d.today.goal_met
  end

  test "899 seconds is not the 15 minute mark and 900 is" do
    add_hours(@user, TODAY, 899)
    refute present.today.quick_met
    add_hours(@user, TODAY, 1)
    assert present.today.quick_met
  end

  test "a later day's hours do not count as today" do
    add_hours(@user, TODAY + 1, 3000)
    assert_equal 0, present.today.minutes
  end

  # --- streaks: the bonus ramp ---

  test "the projected bonus follows the ramp from the streak as it stood when today began" do
    { 0 => [ 5, 7 ], 1 => [ 7, 8.1 ], 13 => [ 20, 20 ], 14 => [ 20, 20 ], 20 => [ 20, 20 ] }.each do |carried, (today_percent, next_percent)|
      user = build_user(created_on: TODAY - 30)
      (1..carried).each { |back| add_hours(user, TODAY - back, QUICK) }
      d = present(user)
      assert_equal carried, d.quick_streak.days, "carried #{carried}"
      assert_equal "Today's bonus: #{format('%g', today_percent)}% once the day closes", d.quick_streak.today_bonus_text, "carried #{carried}"
      assert_equal "Next day: #{format('%g', next_percent)}%", d.quick_streak.next_bonus_text, "carried #{carried}"
      expected_lead = carried.zero? ? "start a streak" : "keep your streak"
      assert_match(/to #{expected_lead}: today's bonus is #{format('%g', today_percent)}% once the day closes\.\z/, d.today.bonus_message)
    end
  end

  test "an active streak counts today once the mark is hit" do
    code_days(TODAY - 2, TODAY - 1)
    d = present
    assert_equal :active, d.quick_streak.state
    assert_equal 2, d.quick_streak.days
    assert_equal "2 days", d.quick_streak.headline
    assert_equal "Code 15 minutes today to reach day 3.", d.quick_streak.message

    add_hours(@user, TODAY, QUICK)
    d = present
    assert_equal 3, d.quick_streak.days
    assert_match(/\AToday counts\. Come back tomorrow for day 4, worth 9\.2%\.\z/, d.quick_streak.message)
    assert_equal "Today's bonus: 8.1% once the day closes", d.quick_streak.today_bonus_text
  end

  test "the daily goal streak is a counter of days at the goal" do
    code_days(TODAY - 2, TODAY - 1, seconds: 3600)
    d = present
    assert_equal :active, d.goal_streak.state
    assert_equal 2, d.goal_streak.days
    assert_nil d.goal_streak.today_bonus_text
    assert_nil d.goal_streak.freeze_text
    assert_equal "Code 60 minutes today to reach day 3.", d.goal_streak.message
    add_hours(@user, TODAY, 3600)
    assert_equal 3, present.goal_streak.days
    assert_equal "Today's goal is done. See you tomorrow.", present.goal_streak.message
  end

  test "15 minute days short of the goal build one streak and not the other" do
    code_days(TODAY - 3, TODAY - 1)
    d = present
    assert_equal 3, d.quick_streak.days
    assert_equal :empty, d.goal_streak.state
  end

  test "yesterday inside the grace period still counts although it is not settled yet" do
    code_days(TODAY - 3, TODAY - 1)
    early = Time.utc(2026, 11, 14, 2)
    Game::Settle.call(@user, through: early)
    assert_equal TODAY - 2, DailyResult.where(user_id: @user.id).maximum(:local_date)
    assert_equal 3, Dashboard::Presenter.new(user: @user, now: early).quick_streak.days
  end

  test "it still works when settling never ran" do
    code_days(TODAY - 3, TODAY - 1)
    assert_equal 3, Dashboard::Presenter.new(user: @user, now: NOW).quick_streak.days
  end

  test "no best is shown while the current streak is the best" do
    code_days(TODAY - 5, TODAY - 1)
    assert_nil present.quick_streak.best_text
  end

  # --- streaks: broken and frozen ---

  test "a broken streak is a gentle fresh start that mentions the best" do
    code_days(TODAY - 9, TODAY - 7)
    d = present
    assert_equal :broken, d.quick_streak.state
    assert_equal 0, d.quick_streak.days
    assert_equal "A fresh start", d.quick_streak.headline
    assert_equal "A fresh start. Your best was 3 days. Code 15 minutes today to begin a new streak.", d.quick_streak.message
    assert_equal "Best: 3 days", d.quick_streak.best_text
    assert_equal "Freeze used on #{(TODAY - 6).strftime('%-d %b')}", d.quick_streak.freeze_text
    assert_equal "Today's bonus: 5% once the day closes", d.quick_streak.today_bonus_text
    refute_match(/fail|lost|miss|shame/i, d.quick_streak.message)
  end

  test "a goal streak that ended is a fresh start too" do
    code_days(TODAY - 9, TODAY - 8, seconds: 3600)
    d = present
    assert_equal :broken, d.goal_streak.state
    assert_match(/\AA fresh start\. Your best was 2 days\./, d.goal_streak.message)
  end

  test "the freeze keeps the streak and the card says so until today is coded" do
    code_days(TODAY - 3, TODAY - 2)
    d = present
    assert_equal :frozen, d.quick_streak.state
    assert_equal 2, d.quick_streak.days
    assert_equal "Your freeze kept your streak alive. Code 15 minutes today to keep it going.", d.quick_streak.message
    assert_equal "Freeze used on #{(TODAY - 1).strftime('%-d %b')}", d.quick_streak.freeze_text
    refute d.quick_streak.freeze_ready

    add_hours(@user, TODAY, QUICK)
    d = present
    assert_equal :active, d.quick_streak.state
    assert_equal 3, d.quick_streak.days
  end

  test "the freeze is ready again after a week of qualifying days" do
    code_days(TODAY - 12, TODAY - 10)
    # the 9th day back is missed (freeze used), then 8 qualifying days re-earn it after 7
    code_days(TODAY - 8, TODAY - 1)
    d = present
    assert d.quick_streak.freeze_ready
    assert_equal "Freeze ready", d.quick_streak.freeze_text
  end

  # --- coins ---

  test "an unverified user has coins they cannot spend yet" do
    give_coins(@user, 120)
    coins = present.coins
    assert_equal 120, coins.total
    assert_equal 0, coins.spendable
    assert_equal "120 coins", coins.total_text
    assert_equal "0 coins", coins.spendable_text
    assert coins.show_spendable
    assert coins.locked
    assert_equal "needs_submission", coins.verification_status
  end

  test "a verified user can spend everything and sees no second balance" do
    give_coins(@user, 1200)
    @user.update_columns(verification_status: "verified")
    coins = present.coins
    assert_equal 1200, coins.spendable
    assert_equal "1,200 coins", coins.total_text
    refute coins.show_spendable
    refute coins.locked
  end

  test "no coins at all is quiet and orders are only linked when there are some" do
    coins = present.coins
    assert_equal 0, coins.total
    refute coins.show_spendable
    refute coins.has_orders
    @user.update_columns(verification_status: "verified")
    give_coins(@user, 100)
    Shop::Purchase.call(user: @user, prize_key: "tshirt", idempotency_key: "k1")
    assert present(User.find(@user.id)).coins.has_orders
  end

  # --- the active project and ships ---

  test "no active project" do
    assert_nil present.project
  end

  test "a project with no linked Hackatime project cannot ship and says why" do
    project = make_project(@user, hackatime: nil)
    panel = present.project
    assert_equal project.id, panel.id
    assert_equal :no_link, panel.readiness
    refute panel.can_ship
    assert_equal 0, panel.linked_count
    assert_equal "No Hackatime project linked yet", panel.linked_text
    assert_match(/\ALink a Hackatime project to this project first/, panel.reason)
  end

  test "a linked project with no coded time yet cannot ship and says why" do
    make_project(@user)
    panel = present.project
    assert_equal :no_hours, panel.readiness
    assert_equal "1 Hackatime project linked", panel.linked_text
    assert_match(/\ANo coded time on this project since your last ship yet/, panel.reason)
  end

  test "a project with less than the minimum hours says how far there is to go" do
    make_project(@user)
    code(@user, TODAY - 1, 1500)
    panel = present.project
    assert_equal :too_few, panel.readiness
    refute panel.can_ship
    assert_equal "25 minutes", panel.window_text
    assert_equal "1 hour", panel.min_text
    assert_equal "You need at least 1 hour on this project to ship. You have 25 minutes so far, 35 minutes to go.", panel.reason
  end

  test "time on another Hackatime project is not counted toward this one" do
    make_project(@user)
    code(@user, TODAY - 1, 7200, hackatime: "something-else")
    assert_equal 0, present.project.window_seconds
  end

  test "a project with enough hours is eligible to ship" do
    make_project(@user)
    code(@user, TODAY - 2, 3600)
    code(@user, TODAY - 1, 1800)
    panel = present.project
    assert_equal :ready, panel.readiness
    assert panel.can_ship
    assert_equal "1 hour 30 minutes", panel.window_text
    assert_nil panel.reason
    assert_nil panel.ship
  end

  test "a draft or waiting ship replaces the Ship button" do
    project = make_project(@user)
    code(@user, TODAY - 1, 3600)
    draft = submit_ship(project, submit: false)
    panel = present.project
    assert_equal :ship_open, panel.readiness
    refute panel.can_ship
    assert_equal [ draft.id, "draft", "Draft", true ], panel.ship.to_h.values_at(:id, :status, :label, :open)

    Ships::Submit.call(project: project, ship: draft, attributes: ship_attrs, submit: true)
    panel = present.project
    assert_equal "Waiting for review", panel.ship.label
    assert_match(/waiting for review/, panel.ship.message)
  end

  test "an approved ship shows the coins it earned and the next ship can start" do
    project = make_project(@user)
    code(@user, TODAY - 5, 3600)
    ship = submit_ship(project)
    Ships::Approve.call(ship: ship, reviewer: users(:onboarded), approved_seconds: 3600, now: NOW)
    code(@user, TODAY - 1, 3600)
    panel = present.project
    assert_equal "approved", panel.ship.status
    assert_match(/\A1 hour approved, \d+ coins? earned\.\z/, panel.ship.message)
    assert_equal :ready, panel.readiness
    assert_equal "1 hour", panel.window_text
  end

  test "a rejected ship carries the reviewer's reason and its time is free to ship again" do
    project = make_project(@user)
    code(@user, TODAY - 1, 3600)
    ship = submit_ship(project)
    Ships::Reject.call(ship: ship, reviewer: users(:onboarded), reason: "The demo link does not open")
    panel = present.project
    assert_equal "rejected", panel.ship.status
    assert_equal "Needs changes", panel.ship.label
    assert_equal "The demo link does not open", panel.ship.reason
    assert_equal :ready, panel.readiness
  end

  test "a withdrawn ship is said gently and is not open" do
    project = make_project(@user)
    code(@user, TODAY - 1, 3600)
    Ships::Withdraw.call(ship: submit_ship(project))
    panel = present.project
    assert_equal "Withdrawn", panel.ship.label
    refute panel.ship.open
  end

  # --- Hackatime ---

  test "Hackatime: not connected, connected and needs reconnect" do
    assert_equal :not_connected, present.hackatime.state
    assert_equal "Not connected", present.hackatime.title

    connection = connect_hackatime(@user)
    d = present(User.find(@user.id))
    assert_equal :connected, d.hackatime.state
    assert_equal "Connected", d.hackatime.title

    connection.mark_needs_reconnect!("token_revoked")
    d = present(User.find(@user.id))
    assert_equal :needs_reconnect, d.hackatime.state
    assert_equal "Needs reconnecting", d.hackatime.title
  end

  # --- prize ---

  test "no chosen prize, no prize panel" do
    assert_nil present.prize
  end

  test "prize progress is coins against the price with the hours wording" do
    @user.update_columns(prize_key: "tshirt")
    give_coins(@user, 20)
    prize = present.prize
    assert_equal "Battletown T-shirt", prize.name
    assert_equal 50, prize.price_coins
    assert_equal "5 hours", prize.hours_text
    assert_equal 20, prize.progress_value
    assert_equal "20 of 50 coins", prize.progress_text
    assert_equal "30 coins to go, about 3 hours of approved coding.", prize.message
    refute prize.reached
  end

  test "prize progress is capped at the price once there are enough coins" do
    @user.update_columns(prize_key: "tshirt")
    give_coins(@user, 80)
    prize = present.prize
    assert_equal 50, prize.progress_value
    assert prize.reached
    assert_equal "You have enough coins for this prize.", prize.message
  end

  test "the free signup sticker has no progress to show" do
    @user.update_columns(prize_key: Prize.free_signup.key)
    prize = present.prize
    assert prize.free
    assert_nil prize.progress_text
  end

  # --- the boss, through the existing presenter ---

  test "the boss card presenter is built for the same local day" do
    assert_equal :none, present.boss.state

    boss = make_boss(starts_on: Date.new(2026, 11, 13), hp_seconds: 100 * HOUR)
    assert_equal :in_progress, present.boss.state

    boss.update_columns(defeated_at: Time.utc(2026, 11, 14, 1))
    assert_equal :defeated, present.boss.state
  end

  test "the boss counts only a headcount of other people, never names" do
    make_boss(starts_on: Date.new(2026, 11, 13))
    other = build_user
    other.update_columns(display_name: "Somebody Else", email: "somebody.else@example.com")
    add_hours(other, TODAY, 1200)
    d = present
    assert_equal "1 person coded today.", d.boss.community_text
    refute_includes [ d.today.to_h, d.quick_streak.to_h, d.coins.to_h, d.boss.summary, d.boss.community_text ].to_s, "Somebody"
  end
end
