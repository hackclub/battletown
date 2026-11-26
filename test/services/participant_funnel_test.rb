require "test_helper"

# ParticipantFunnel and its derived funnel_stage, over the insights views (plans/analytics.md sections 3.3 and 4): each step's count, nested never
# rising, the ever-reached medians, retroactivity (no events needed), exclusion, small-cell suppression, and the visitor funnel.
class ParticipantFunnelTest < ActiveSupport::TestCase
  T0 = Time.utc(2026, 11, 2, 12) # everyone signs up on Monday 2 November at noon UTC

  setup do
    @original = ENV.values_at("ADMIN_HCA_UIDS", "ANALYTICS_EXCLUDE_HCA_UIDS")
    ENV.delete("ADMIN_HCA_UIDS")
    ENV.delete("ANALYTICS_EXCLUDE_HCA_UIDS")
    User.update_all(analytics_excluded: true) # the two fixture users stay out of every count
  end

  teardown do
    ENV["ADMIN_HCA_UIDS"] = @original.first
    ENV["ANALYTICS_EXCLUDE_HCA_UIDS"] = @original.last
    ENV.delete("ADMIN_HCA_UIDS") if @original.first.nil?
    ENV.delete("ANALYTICS_EXCLUDE_HCA_UIDS") if @original.last.nil?
  end

  # --- builders: one person per funnel stage, from the product tables only (no event exists anywhere) ---

  def person(key, signed_up: T0, **attrs) = User.create!(hca_uid: "ident!#{key}", created_at: signed_up, **attrs)

  def onboard(user, at: T0 + 1.hour) = user.update_columns(onboarded_at: at, onboarding_step: 6)

  def connect(user, at: T0 + 2.hours)
    HackatimeConnection.create!(user: user, hackatime_uid: user.id.to_s, access_token: "t", scopes: "profile read", connected_at: at)
  end

  def project_for(user, at: T0 + 3.hours)
    project = Project.create!(user: user, name: "P#{user.id}", kind: "game")
    link = project.hackatime_links.create!(user_id: user.id, hackatime_project: "p#{user.id}", link_method: "manual")
    link.update_columns(created_at: at)
    project
  end

  def hours(user, date, seconds, key = SecureRandom.hex(4))
    HourEntry.create!(user: user, local_date: date, seconds: seconds, source: "manual", note: "test", idempotency_key: "pf-#{user.id}-#{key}")
  end

  def ship(user, project, status: "submitted", at: T0 + 2.days, approved: false)
    attrs = { user: user, project: project, status: status, description: "x", repo_url: "https://github.com/a/b", coded_seconds: 3600,
              window_start_date: Date.new(2026, 11, 3), window_end_date: Date.new(2026, 11, 3), daily_seconds: { "2026-11-03" => 3600 }, submitted_at: at }
    attrs.merge!(reviewed_at: at + 1.day, approved_seconds: 3000) if approved
    Ship.create!(**attrs)
  end

  def buy(user, status: "requested", kind: "purchase", at: T0 + 4.days)
    coins = kind == "purchase" ? 20 : 0
    order = Order.create!(user: user, prize_key: "sticker_pack", prize_name: "Stickers", coins: coins, kind: kind, idempotency_key: "pf-#{user.id}-#{kind}-#{status}")
    order.update_columns(status: status, created_at: at, cancelled_at: (at if status == "cancelled"), refunded_at: (at if status == "refunded"))
    order
  end

  # Nine people, one stopping at each stage; returns them by the last step they reached.
  def ladder
    people = {}
    people[:signed_up] = person("a")
    people[:onboarded] = person("b").tap { |user| onboard(user) }
    people[:linked_hackatime] = person("c").tap { |user| onboard(user); connect(user) }
    people[:added_project] = person("d").tap { |user| onboard(user); connect(user); project_for(user) }
    people[:first_active_day] = person("e").tap { |user| onboard(user); connect(user); project_for(user); hours(user, Date.new(2026, 11, 4), 1200) }
    people[:past_5h] = person("f").tap { |user| onboard(user); connect(user); project_for(user); hours(user, Date.new(2026, 11, 4), 1200); hours(user, Date.new(2026, 11, 5), 17_000) }
    people[:shipped] = person("g").tap { |user| onboard(user); connect(user); ship(user, project_for(user)); hours(user, Date.new(2026, 11, 4), 40_000) }
    people[:approved] = person("h").tap { |user| onboard(user); connect(user); ship(user, project_for(user), status: "approved", approved: true); hours(user, Date.new(2026, 11, 4), 40_000) }
    people[:bought] = person("i").tap do |user|
      onboard(user); connect(user); ship(user, project_for(user), status: "approved", approved: true); hours(user, Date.new(2026, 11, 4), 40_000); buy(user)
    end
    people
  end

  def counts(rows) = rows.to_h { |row| [ row[:key], row[:count] ] }

  # --- the nine steps ---

  test "each step counts the people who reached it, nested and on its own" do
    ladder
    result = ParticipantFunnel.run

    assert_equal 9, result[:total]
    assert_not result[:filtered]
    assert_equal({ signed_up: 9, onboarded: 8, linked_hackatime: 7, added_project: 6, first_active_day: 5, past_5h: 4, shipped: 3, approved: 2, bought: 1 }, counts(result[:nested]))
    assert_equal({ signed_up: 9, onboarded: 8, linked_hackatime: 7, added_project: 6, first_active_day: 5, past_1h: 4, past_5h: 4, past_10h: 3, shipped: 3, approved: 2, bought: 1 },
                 counts(result[:ever_reached]))
  end

  test "nested never rises and kept percent stays at or under 100" do
    ladder
    nested = ParticipantFunnel.run[:nested]
    assert_equal nested.map { |row| row[:count] }.sort.reverse, nested.map { |row| row[:count] }
    nested.each { |row| assert_operator row[:kept_percent], :<=, 100 }
    assert_equal [ 100.0, 88.9, 87.5, 85.7, 83.3, 80.0, 75.0, 66.7, 50.0 ], nested.map { |row| row[:kept_percent] }
    assert_equal [ 0, 1, 1, 1, 1, 1, 1, 1, 1 ], nested.map { |row| row[:lost] }
  end

  test "steps reached out of order count on their own but not nested" do
    skipper = person("skip") # bought and shipped without ever onboarding or linking Hackatime
    ship(skipper, project_for(skipper))
    buy(skipper)
    result = ParticipantFunnel.run

    assert_equal 1, result[:total]
    assert_equal 1, counts(result[:ever_reached])[:bought]
    assert_equal 1, counts(result[:ever_reached])[:shipped]
    assert_equal 0, counts(result[:nested])[:onboarded]
    assert_equal 0, counts(result[:nested])[:bought]
  end

  test "retroactive: it works from the product tables with no analytics event at all" do
    ladder
    assert_equal 0, AnalyticsEvent.where.not(name: "project_linked").count
    assert_equal 9, ParticipantFunnel.run[:total]
    assert_equal 1, counts(ParticipantFunnel.run[:nested])[:bought]
  end

  test "an empty program returns zeros, not errors" do
    result = ParticipantFunnel.run
    assert_equal 0, result[:total]
    assert_equal [ 0 ] * 9, result[:nested].map { |row| row[:count] }
    assert_equal [ 0.0 ] * 9, result[:nested].map { |row| row[:kept_percent] }
    assert result[:ever_reached].all? { |row| row[:median_seconds].nil? }
    assert_equal({ visited: 0, age: 0, prize: 0, project: 0, schedule: 0, signup: 0, ineligible: 0, signup_started: 0, signed_up: 0 }, ParticipantFunnel.visits)
    assert_equal [], ParticipantFunnel.cohorts
  end

  test "added_project needs a Hackatime link, not a bare project" do
    bare = person("bare")
    onboard(bare)
    connect(bare)
    Project.create!(user: bare, name: "Bare", kind: "game")
    assert_equal 0, counts(ParticipantFunnel.run[:ever_reached])[:added_project]
    project_for(bare)
    assert_equal 1, counts(ParticipantFunnel.run[:ever_reached])[:added_project]
  end

  test "linked_hackatime counts a connection, or hackatime ledger rows after a disconnect, but not a manual hour" do
    connected = person("conn")
    connect(connected)
    credited = person("cred")
    HourEntry.create!(user: credited, local_date: Date.new(2026, 11, 3), seconds: 600, source: "hackatime", hackatime_project: "x", idempotency_key: "pf-cred")
    manual_only = person("man")
    hours(manual_only, Date.new(2026, 11, 3), 600)
    assert_equal 2, counts(ParticipantFunnel.run[:ever_reached])[:linked_hackatime]
  end

  test "the free sticker is not a purchase, a refunded purchase is, a cancelled one is not" do
    sticker = person("stk")
    buy(sticker, kind: "signup_sticker")
    refunded = person("ref")
    buy(refunded, status: "refunded")
    cancelled = person("can")
    buy(cancelled, status: "cancelled")
    assert_equal 1, counts(ParticipantFunnel.run[:ever_reached])[:bought]
  end

  test "first_active_day needs the quick threshold on a counted date, past_5h the running total" do
    early = person("early", signed_up: Time.utc(2026, 11, 10, 12)) # signs up on the 10th: hours on the 4th are before the counted window
    hours(early, Date.new(2026, 11, 4), 36_000)
    short = person("short")
    hours(short, Date.new(2026, 11, 4), 899) # one second under 15 minutes
    exact = person("exact")
    hours(exact, Date.new(2026, 11, 4), 900)
    split = person("split") # five days of an hour each: the running total reaches 5 hours
    5.times { |day| hours(split, Date.new(2026, 11, 3) + day, 3600) }

    ever = counts(ParticipantFunnel.run[:ever_reached])
    assert_equal 2, ever[:first_active_day] # exact (15 minutes) and split; short is a second under, and early's hours are before its counted window
    assert_equal 1, ever[:past_1h] # split
    assert_equal 1, ever[:past_5h] # split
  end

  test "a negative adjustment floors that day at zero and never lowers another day" do
    user = person("adj")
    hours(user, Date.new(2026, 11, 3), 3600)
    HourEntry.create!(user: user, local_date: Date.new(2026, 11, 4), seconds: -1800, source: "adjustment", note: "fix", idempotency_key: "pf-adj")
    assert_equal 1, counts(ParticipantFunnel.run[:ever_reached])[:past_1h]
  end

  # --- timing ---

  test "ever reached medians come from the nearest earlier step that has a time, only for people with both in order" do
    fast = person("fast")
    onboard(fast, at: T0 + 1.hour)
    connect(fast, at: T0 + 3.hours) # 2 hours after onboarding
    slow = person("slow")
    onboard(slow, at: T0 + 3.hours)
    connect(slow, at: T0 + 9.hours) # 6 hours after
    jumper = person("jump") # never onboarded: linked is timed from signing up (the nearest earlier step with a time)
    connect(jumper, at: T0 + 10.hours)
    project_for(fast, at: T0 + 5.hours)

    by_key = ParticipantFunnel.run[:ever_reached].index_by { |row| row[:key] }
    assert_equal [ 3600 * 2, 2 ], by_key[:onboarded].values_at(:median_seconds, :timed)
    assert_equal [ 21_600, 3 ], by_key[:linked_hackatime].values_at(:median_seconds, :timed) # 2 h and 6 h after onboarding, 10 h after signing up
    assert_equal [ 7200, 1 ], by_key[:added_project].values_at(:median_seconds, :timed)
  end

  test "a date step is measured from midnight UTC of its local date" do
    user = person("dated")
    onboard(user, at: T0 + 1.hour)
    connect(user, at: T0 + 2.hours)
    project_for(user, at: T0 + 3.hours) # Monday 15:00
    hours(user, Date.new(2026, 11, 4), 900) # Wednesday: 00:00 is 33 hours after the project link
    row = ParticipantFunnel.run[:ever_reached].find { |r| r[:key] == :first_active_day }
    assert_equal [ 33 * 3600, 1 ], row.values_at(:median_seconds, :timed)
  end

  # --- filters and small cells ---

  test "an unfiltered funnel is never suppressed, however small" do
    person("only")
    assert_equal 1, ParticipantFunnel.run[:total]
    assert_equal 0, ParticipantFunnel.run[:nested][1][:count]
  end

  test "a filtered funnel hides a step of one to four people and shows five" do
    5.times { |i| person("h#{i}", referral_source: "haven").tap { |user| onboard(user) } }
    4.times { |i| connect(User.find_by!(hca_uid: "ident!h#{i}")) }
    person("other", referral_source: "other").tap { |user| onboard(user) }

    haven = ParticipantFunnel.run(cohort: "haven")
    assert haven[:filtered]
    assert_equal 5, haven[:total]
    assert_equal 5, counts(haven[:nested])[:onboarded], "five is shown"
    assert_equal "<5", counts(haven[:nested])[:linked_hackatime], "four is hidden"
    assert_nil haven[:nested][2][:kept_percent]
    assert_nil haven[:nested][2][:lost]
    assert_equal "<5", counts(haven[:ever_reached])[:linked_hackatime]
    assert_equal "<5", haven[:ever_reached].find { |row| row[:key] == :linked_hackatime }[:timed]
    assert_nil haven[:ever_reached].find { |row| row[:key] == :linked_hackatime }[:median_seconds]

    assert_equal 1, ParticipantFunnel.run(cohort: "other")[:total]
    assert_equal 6, ParticipantFunnel.run[:total]
  end

  test "the sign-up window is inclusive of its last day" do
    person("mon", signed_up: Time.utc(2026, 11, 2, 23, 59))
    person("tue", signed_up: Time.utc(2026, 11, 3, 0, 0))
    person("wed", signed_up: Time.utc(2026, 11, 4, 8))
    assert_equal 1, ParticipantFunnel.run(since: Date.new(2026, 11, 2), until: Date.new(2026, 11, 2))[:total]
    assert_equal 2, ParticipantFunnel.run(since: Date.new(2026, 11, 3), until: Date.new(2026, 11, 4))[:total]
    assert_equal 2, ParticipantFunnel.run(until: Date.new(2026, 11, 3))[:total]
    assert_equal 2, ParticipantFunnel.run(since: Date.new(2026, 11, 3))[:total]
  end

  # --- exclusion ---

  test "staff, simulated players and listed testers move no number" do
    ladder
    before = ParticipantFunnel.run
    ENV["ADMIN_HCA_UIDS"] = "ident!staff"
    ENV["ANALYTICS_EXCLUDE_HCA_UIDS"] = "ident!friend"
    %w[ident!staff sim!ada ident!friend].each_with_index do |uid, index|
      user = User.create!(hca_uid: uid, created_at: T0)
      onboard(user)
      connect(user)
      ship(user, project_for(user), status: "approved", approved: true)
      hours(user, Date.new(2026, 11, 4), 40_000)
      buy(user, at: T0 + 5.days + index.minutes)
    end
    assert_equal before, ParticipantFunnel.run
  end

  # --- funnel_stage ---

  test "the stage is the first step not reached, and since when" do
    people = ladder
    expected = { signed_up: :onboarded, onboarded: :linked_hackatime, linked_hackatime: :added_project, added_project: :first_active_day, first_active_day: :past_5h,
                 past_5h: :shipped, shipped: :approved, approved: :bought, bought: :completed }
    expected.each { |reached, stage| assert_equal stage, ParticipantFunnel::Stage.for(people.fetch(reached)).key, "after #{reached}" }
    assert_equal "Onboarded", ParticipantFunnel::Stage.for(people[:signed_up]).label
    assert_equal "Completed the funnel", ParticipantFunnel::Stage.for(people[:bought]).label
  end

  test "stuck since is the latest step reached, and out-of-order steps leave the first gap as the stage" do
    user = person("late")
    onboard(user, at: T0 + 1.hour)
    connect(user, at: T0 + 2.hours)
    ship(user, project_for(user, at: T0 + 3.hours), at: T0 + 30.hours) # shipped without an active day: the gap is first_active_day, since the ship
    stage = ParticipantFunnel::Stage.for(user)
    assert_equal :first_active_day, stage.key
    assert_equal T0 + 30.hours, stage.entered_at.in_time_zone("UTC")
    assert_equal 1, stage.days_stuck(now: T0 + 30.hours + 25.hours)
  end

  test "a person who is not measured has no stage" do
    assert_nil ParticipantFunnel::Stage.for(users(:onboarded))
    assert_nil ParticipantFunnel::Stage.for(User.create!(hca_uid: "sim!stage", created_at: T0))
  end

  test "stuck lists people per stage with the median days, hiding cells under five" do
    5.times { |i| person("s#{i}", signed_up: T0 - i.days) }
    3.times { |i| person("o#{i}").tap { |user| onboard(user) } }
    rows = ParticipantFunnel.stuck(now: T0 + 4.days).index_by { |row| row[:stage] }
    assert_equal ParticipantFunnel::STAGES, ParticipantFunnel.stuck(now: T0).map { |row| row[:stage] }
    assert_equal 5, rows[:onboarded][:people]
    assert_equal 6.0, rows[:onboarded][:median_days] # signed up 0..4 days before T0, so 4..8 days before T0 + 4 days: the median is 6
    assert_equal "<5", rows[:linked_hackatime][:people]
    assert_nil rows[:linked_hackatime][:median_days]
    assert_equal "<5", rows[:completed][:people]
  end

  # --- the visitor funnel (events, before sign-up) ---

  def visit(events, started: T0, user: nil, **attrs)
    visit = AnalyticsVisit.create!(visit_key: SecureRandom.alphanumeric(22), started_at: started, user: user, **attrs)
    events.each do |name, props|
      AnalyticsEvent.create!(name: name, props: props || {}, visit: visit, user: user, occurred_at: started)
    end
    visit
  end

  def page(step) = [ "onboarding_step_viewed", { "step" => step } ]

  test "the visitor funnel counts distinct visits that reached each step" do
    full = [ [ "landing_viewed" ], page("age"), page("prize"), page("project"), page("schedule"), page("signup"), [ "signup_started" ], [ "signed_up" ] ]
    visit([ [ "landing_viewed" ] ])
    visit([ [ "landing_viewed" ], page("age"), page("age") ]) # two views of one step count once
    visit([ page("age"), page("prize") ]) # arrived mid-flow (no landing view): still a visit
    visit([ [ "landing_viewed" ], page("age"), [ "onboarding_ineligible" ] ])
    visit(full, user: person("v1"))
    visit([]) # a visit with no funnel event is not "visited"

    totals = ParticipantFunnel.visits
    assert_equal({ visited: 5, age: 4, prize: 2, project: 1, schedule: 1, signup: 1, ineligible: 1, signup_started: 1, signed_up: 1 }, totals)
  end

  test "a returning player who pressed the sign-in button is not counted as a sign-up attempt" do
    visit([ [ "landing_viewed" ], [ "signup_started" ], [ "signed_in" ] ], user: person("v2"))
    visit([ [ "landing_viewed" ], [ "signup_started" ] ]) # pressed, did not come back: could be either
    visit([ [ "landing_viewed" ], [ "signup_started" ], [ "signed_up" ] ], user: person("v3"))

    totals = ParticipantFunnel.visits
    assert_equal 2, totals[:signup_started]
    assert_equal 1, totals[:signed_up]
  end

  test "the visitor funnel respects the window and leaves out visits of staff and sims" do
    visit([ [ "landing_viewed" ] ], started: Time.utc(2026, 11, 2, 8))
    visit([ [ "landing_viewed" ] ], started: Time.utc(2026, 11, 3, 8))
    visit([ [ "landing_viewed" ] ], user: User.create!(hca_uid: "sim!visit", created_at: T0))
    assert_equal 1, ParticipantFunnel.visits(since: Date.new(2026, 11, 2), until: Date.new(2026, 11, 2))[:visited]
    assert_equal 2, ParticipantFunnel.visits[:visited]
  end

  test "visits by referral hides cells under five, and a missing slug is none" do
    5.times { visit([ [ "landing_viewed" ] ], referral_slug: "haven") }
    4.times { visit([ [ "landing_viewed" ] ], referral_slug: "terra") }
    3.times { visit([ [ "landing_viewed" ] ], referral_slug: nil) }
    visit(%w[signed_up].map { |name| [ name ] }, referral_slug: "haven")

    rows = ParticipantFunnel.visits_by(:referral_slug).index_by { |row| row[:value] }
    assert_equal %w[haven none terra], rows.keys.sort
    assert_equal 5, rows["haven"][:visited]
    assert_equal "<5", rows["haven"][:signed_up], "one signed-up visit is a small cell"
    assert_equal "<5", rows["terra"][:visited]
    assert_equal "<5", rows["none"][:age]
    assert_equal "haven", ParticipantFunnel.visits_by(:referral_slug).first[:value], "biggest first"
    assert_raises(ArgumentError) { ParticipantFunnel.visits_by(:token) }
    assert_equal %w[unknown], ParticipantFunnel.visits_by(:device_class).map { |row| row[:value] }, "device class is a dimension too"
  end

  # --- cohorts ---

  test "cohorts count sign-up weeks, with day-1 and day-7 return among those whose day has passed" do
    friday = Time.utc(2026, 11, 6, 10) # the week starts on Friday 6 November
    people = Array.new(6) { |i| person("c#{i}", signed_up: friday + i.minutes) }
    people.first(5).each { |user| AnalyticsSiteDay.create!(user: user, day: Date.new(2026, 11, 7)) } # five come back the next day
    hours(people.last, Date.new(2026, 11, 7), 600) # the sixth came back through counted hours
    people.first(2).each { |user| AnalyticsSiteDay.create!(user: user, day: Date.new(2026, 11, 13)) }
    person("old", signed_up: Time.utc(2026, 10, 30, 10)) # the week before

    weeks = ParticipantFunnel.cohorts(today: Date.new(2026, 11, 14))
    assert_equal [ Date.new(2026, 10, 30), Date.new(2026, 11, 6) ], weeks.map { |week| week[:week_starts_on] }
    week = weeks.last
    assert_equal 6, week[:people]
    assert_equal({ eligible: 6, returned: 6, percent: 100.0 }, week[:day1])
    assert_equal({ eligible: 6, returned: "<5", percent: nil }, week[:day7])
    assert_equal "<5", weeks.first[:day1][:eligible], "a week of one person is a small cell"

    early = ParticipantFunnel.cohorts(today: Date.new(2026, 11, 8)).last
    assert_equal 6, early[:day1][:eligible]
    assert_equal "<5", early[:day7][:eligible], "day 7 has not passed yet for anyone"
    assert_equal 1, ParticipantFunnel.cohorts(today: Date.new(2026, 11, 14), since: Date.new(2026, 10, 30), until: Date.new(2026, 10, 31)).size
  end
end
