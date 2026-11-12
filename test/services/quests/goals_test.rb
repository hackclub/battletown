require "test_helper"
require_relative "../../support/quests_helper"

class Quests::GoalsTest < ActiveSupport::TestCase
  include QuestsHelper

  FRI = QuestsHelper::WEEK_START
  SAT = FRI + 1
  SUN = FRI + 2
  MON = FRI + 3
  QUARTER = 900

  setup do
    travel_to QuestsHelper::NOW
    @user = quest_user
  end

  def at(day, hour = 12) = Time.utc(2026, 11, day, hour)

  def check(quest, user = @user) = Quests::Goals.check(user, quest)

  # --- the pure part ---

  test "qualifying_days keeps the first moment each date reached the bar, and drops a date a correction took back under it" do
    entries = [ [ FRI, 600, at(13, 9) ], [ FRI, 300, at(13, 10) ], [ SAT, 899, at(14, 9) ], [ SUN, 1000, at(15, 9) ], [ SUN, -50, at(15, 10) ] ]
    days = Quests::Goals.qualifying_days(entries, QUARTER)

    assert_equal [ FRI, SUN ], days.keys
    assert_equal at(13, 10), days[FRI], "the bar (exactly 15 minutes) is reached by the second row"
    assert_equal at(15, 9), days[SUN], "a later correction that stays above the bar changes nothing"

    dropped = Quests::Goals.qualifying_days(entries + [ [ SUN, -400, at(15, 11) ] ], QUARTER)
    assert_equal [ FRI ], dropped.keys
  end

  # --- code_days ---

  test "code_days counts local dates at 15 minutes or more inside the week, and completes at the moment the Nth date reached the bar" do
    quest = make_quest(goal_key: "code_days", target: 3)
    code_at(@user, FRI, QUARTER, recorded_at: at(13, 9))
    code_at(@user, SAT, QUARTER - 1, recorded_at: at(14, 9))
    code_at(@user, SUN, 3600, recorded_at: at(15, 9))

    progress = check(quest)
    assert_equal [ 2, 3, nil ], [ progress.current, progress.target, progress.completed_at ]
    assert_not progress.complete?

    code_at(@user, SAT, 1, recorded_at: at(16, 8)) # the Saturday bar is reached late (a late sync)
    progress = check(quest)
    assert_equal [ 3, 3 ], [ progress.current, progress.target ]
    assert_equal at(16, 8), progress.completed_at, "the third date to reach the bar is the one that finishes it, whenever it was synced"
  end

  test "code_days ignores dates just outside the week" do
    quest = make_quest(goal_key: "code_days", target: 1)
    code_at(@user, FRI - 1, 3600, recorded_at: at(12, 9))
    code_at(@user, QuestsHelper::WEEK_END + 1, 3600, recorded_at: at(20, 9))
    assert_equal 0, check(quest).current

    code_at(@user, QuestsHelper::WEEK_END, 3600, recorded_at: at(19, 9))
    assert check(quest).complete?
  end

  test "code_days leaves out dates before the person signed up" do
    quest = make_quest(goal_key: "code_days", target: 2)
    late = quest_user(created_on: SAT)
    code_at(late, FRI, 3600, recorded_at: at(13, 9)) # in the ledger, but before the sign-up date: counts for nothing
    code_at(late, SAT, 3600, recorded_at: at(14, 9))

    progress = check(quest, late)
    assert_equal 1, progress.current
    code_at(late, SUN, 3600, recorded_at: at(15, 9))
    assert_equal at(15, 9), check(quest, late).completed_at
  end

  test "code_days with the bar written in config uses Game::Config quick_minutes" do
    assert_equal 900, Quests::Goals.threshold
  end

  test "code_days works from the local date on the row, so a time zone far ahead of UTC counts its own Friday" do
    quest = make_quest(goal_key: "code_days", target: 1)
    nz = quest_user(time_zone: "Pacific/Auckland")
    # 23:00 UTC on Thursday the 12th is already Friday the 13th in Auckland; the ledger stored the local date.
    code_at(nz, FRI, 3600, recorded_at: Time.utc(2026, 11, 12, 23))
    assert check(quest, nz).complete?
    assert_equal Time.utc(2026, 11, 12, 23), check(quest, nz).completed_at
  end

  # --- streak_days ---

  test "streak_days needs consecutive qualifying dates and completes when the run was whole" do
    quest = make_quest(goal_key: "streak_days", target: 3)
    code_at(@user, FRI, QUARTER, recorded_at: at(13, 9))
    code_at(@user, SAT, QUARTER, recorded_at: at(14, 9))
    code_at(@user, MON, QUARTER, recorded_at: at(16, 9)) # a gap on Sunday

    progress = check(quest)
    assert_equal [ 2, 3, nil ], [ progress.current, progress.target, progress.completed_at ]

    code_at(@user, SUN, QUARTER, recorded_at: at(17, 9)) # Sunday filled in late
    progress = check(quest)
    assert_equal 3, progress.current
    assert_equal at(17, 9), progress.completed_at, "Fri, Sat, Sun is whole when Sunday lands (Sat, Sun, Mon needs Sunday too)"
  end

  test "streak_days picks the earliest moment any run of the target length was whole" do
    quest = make_quest(goal_key: "streak_days", target: 2)
    code_at(@user, FRI, QUARTER, recorded_at: at(13, 9))
    code_at(@user, SAT, QUARTER, recorded_at: at(14, 9))
    code_at(@user, SUN, QUARTER, recorded_at: at(15, 9))
    assert_equal at(14, 9), check(quest).completed_at
  end

  test "streak_days does not count a streak that started before the week" do
    quest = make_quest(goal_key: "streak_days", target: 3)
    code_at(@user, FRI - 2, QUARTER, recorded_at: at(11, 9))
    code_at(@user, FRI - 1, QUARTER, recorded_at: at(12, 9))
    code_at(@user, FRI, QUARTER, recorded_at: at(13, 9))
    assert_equal 1, check(quest).current
    assert_not check(quest).complete?
  end

  # --- ship_project, link_hackatime, add_project (instants, in the person's own time zone) ---

  def ship_at(user, submitted_at, status: "submitted")
    project = Project.create!(user: user, name: "P#{SecureRandom.hex(3)}", kind: "game")
    Ship.create!(user: user, project: project, status: status, description: "Built it", repo_url: "https://github.com/octo/space-farm", coded_seconds: 3600,
                 window_start_date: FRI, window_end_date: FRI, daily_seconds: { FRI.iso8601 => 3600 }, submitted_at: submitted_at,
                 reviewed_at: (submitted_at if %w[approved rejected].include?(status)), approved_seconds: (3600 if status == "approved"),
                 rejection_reason: ("No" if status == "rejected"))
  end

  test "ship_project counts a ship sent in during the week (submitted or approved), not a draft, a withdrawn or a rejected one" do
    quest = make_quest(goal_key: "ship_project", target: nil)
    ship_at(@user, at(14, 9), status: "withdrawn")
    ship_at(@user, at(14, 9), status: "rejected")
    assert_equal [ 0, 1 ], [ check(quest).current, check(quest).target ]
    ship_at(@user, at(15, 9), status: "approved")
    ship_at(@user, at(16, 9))

    progress = check(quest)
    assert_equal [ 1, 1, at(15, 9) ], [ progress.current, progress.target, progress.completed_at ]
  end

  test "ship_project ignores a ship sent in before the week started" do
    quest = make_quest(goal_key: "ship_project", target: nil)
    ship_at(@user, at(12, 9))
    assert_not check(quest).complete?
  end

  test "link_hackatime counts a link made during the week" do
    quest = make_quest(goal_key: "link_hackatime", target: nil)
    project = Project.create!(user: @user, name: "Linked", kind: "game")
    link = project.hackatime_links.create!(user_id: @user.id, hackatime_project: "linked", link_method: "manual")
    link.update_columns(created_at: at(12, 9))
    assert_not check(quest).complete?

    link.update_columns(created_at: at(14, 9))
    assert_equal at(14, 9), check(quest).completed_at
  end

  test "add_project counts a project added during the week" do
    quest = make_quest(goal_key: "add_project", target: nil)
    project = Project.create!(user: @user, name: "Mine", kind: "game")
    project.update_columns(created_at: at(12, 9))
    assert_not check(quest).complete?

    project.update_columns(created_at: at(18, 9))
    assert_equal at(18, 9), check(quest).completed_at
  end

  test "the week is the person's own local week: Auckland starts Friday 13 hours before UTC and ends 13 hours before it too" do
    quest = make_quest(goal_key: "add_project", target: nil)
    nz = quest_user(time_zone: "Pacific/Auckland")
    utc = quest_user
    early = Project.create!(user: nz, name: "Early", kind: "game")
    early.update_columns(created_at: Time.utc(2026, 11, 12, 12)) # Friday 01:00 in Auckland, still Thursday in UTC
    Project.create!(user: utc, name: "Early", kind: "game").update_columns(created_at: Time.utc(2026, 11, 12, 12))
    assert check(quest, nz).complete?
    assert_not check(quest, utc).complete?

    late_nz = quest_user(time_zone: "Pacific/Auckland")
    Project.create!(user: late_nz, name: "Late", kind: "game").update_columns(created_at: Time.utc(2026, 11, 19, 12)) # Friday 01:00 in Auckland: next week
    late_utc = quest_user
    Project.create!(user: late_utc, name: "Late", kind: "game").update_columns(created_at: Time.utc(2026, 11, 19, 12))
    assert_not check(quest, late_nz).complete?
    assert check(quest, late_utc).complete?
  end

  test "a person who signed up after the week cannot have done anything in it" do
    quest = make_quest(goal_key: "code_days", target: 1)
    newcomer = quest_user(created_on: QuestsHelper::WEEK_END + 2)
    code_at(newcomer, QuestsHelper::WEEK_END, 3600, recorded_at: at(19, 9))
    assert_not check(quest, newcomer).complete?
  end
end
