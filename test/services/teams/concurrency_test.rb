require "test_helper"
require_relative "../../support/coins_helper"
require_relative "../../support/ships_test_support"

# Real threads on real connections (so no transactional tests): two approvals at once, the same payout twice, and a crew
# filling up. Each test deletes what it made (the database cascades).
class Teams::ConcurrencyTest < ActiveSupport::TestCase
  include CoinsHelper
  include ShipsTestSupport

  self.use_transactional_tests = false

  D = ->(day) { Date.new(2026, 11, day) }
  NOW = Time.utc(2026, 11, 10, 12)

  setup do
    Flipper.enable(:team)
    @made = []
  end

  teardown do
    Teams::Config.reset!
    Team.where(id: TeamMembership.where(user_id: @made.map(&:id)).select(:team_id)).delete_all
    User.where(id: @made.map(&:id)).delete_all
    Team.sweep_empty!
  end

  def user!
    build_user(created_on: D[1]).tap { |user| @made << user }
  end

  def race(*blocks)
    gate = Queue.new
    ready = Queue.new
    threads = blocks.map do |block|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          gate.pop
          [ :ok, block.call ]
        rescue StandardError => error
          [ :error, error ]
        end
      end
    end
    blocks.size.times { Timeout.timeout(20) { ready.pop } }
    blocks.size.times { gate << true }
    threads.map(&:value)
  end

  # A crew of two where the mate coded 4 hours on each of Nov 1 to 4.
  def crew_with_mate
    user = user!
    mate = user!
    team = Team.create!(invite_token: Team.new_token, invite_expires_at: 1.day.from_now)
    [ user, mate ].each { |member| TeamMembership.create!(team: team, user: member, joined_at: Time.utc(2026, 10, 31)) }
    (1..4).each { |day| code(mate, D[day], 4 * HOUR) }
    [ user, mate, team ]
  end

  test "two ships of one person approved at the same moment each pay their own bonus exactly once" do
    user, _mate, _team = crew_with_mate
    reviewer = user!
    first = make_project(user, name: "One", hackatime: "one")
    second = make_project(user, name: "Two", hackatime: "two")
    (1..2).each { |day| code(user, D[day], 4 * HOUR, hackatime: "one") }
    (3..4).each { |day| code(user, D[day], 4 * HOUR, hackatime: "two") }
    ships = [ submit_ship(first), submit_ship(second) ]

    outcomes = race(*ships.map { |ship| -> { Ships::Approve.call(ship: Ship.find(ship.id), reviewer: User.find(reviewer.id), approved_seconds: ship.coded_seconds, now: NOW) } })

    assert(outcomes.all? { |kind, _| kind == :ok }, outcomes.map(&:last).inspect)
    rows = CoinTransaction.where(user_id: user.id, kind: "team_bonus")
    assert_equal ships.map { |ship| "team_bonus:ship:#{ship.id}" }.sort, rows.pluck(:idempotency_key).sort
    assert_equal 2, TeamPayout.where(user_id: user.id).count
    assert_equal TeamPayout.where(user_id: user.id).sum(:coins), rows.sum(:amount)
    assert_operator rows.sum(:amount), :>, 0
  end

  test "the same ship paid by several workers at once credits once" do
    user, _mate, _team = crew_with_mate
    reviewer = user!
    project = make_project(user)
    (1..3).each { |day| code(user, D[day], 4 * HOUR) }
    ship = submit_ship(project)
    Flipper.disable(:team)
    Ships::Approve.call(ship: ship, reviewer: reviewer, approved_seconds: ship.coded_seconds, now: NOW)
    Flipper.enable(:team)

    pay = -> { Teams::PayShip.call(Ship.find(ship.id)) }
    outcomes = race(pay, pay, pay, -> { Teams::PayPending.scan(now: NOW) })

    assert(outcomes.all? { |kind, _| kind == :ok }, outcomes.map(&:last).inspect)
    assert_equal 1, CoinTransaction.where(user_id: user.id, kind: "team_bonus").count
    assert_equal 1, TeamPayout.where(ship_id: ship.id).count
  end

  test "people joining a nearly full crew at once never overfill it" do
    Teams::Config.instance_variable_set(:@current, Teams::Config.current.with(max_size: 3)) # the connection pool allows a handful of threads
    team = Teams::Crew.create!(user: user!)
    joiners = Array.new(3) { user! }

    outcomes = race(*joiners.map { |user| -> { Teams::Crew.join!(user: User.find(user.id), token: team.invite_token) } })

    assert_equal 3, TeamMembership.where(team_id: team.id).count
    failures = outcomes.select { |kind, _| kind == :error }.map(&:last)
    assert_equal 1, failures.size
    assert(failures.all? { |error| error.is_a?(Teams::Crew::Full) }, failures.inspect)
  end

  test "one person joining two crews at once ends up in exactly one" do
    one = Teams::Crew.create!(user: user!)
    two = Teams::Crew.create!(user: user!)
    joiner = user!

    outcomes = race(-> { Teams::Crew.join!(user: User.find(joiner.id), token: one.invite_token) },
                    -> { Teams::Crew.join!(user: User.find(joiner.id), token: two.invite_token) })

    assert_equal 1, outcomes.count { |kind, _| kind == :ok }
    assert_equal 1, TeamMembership.where(user_id: joiner.id).count
  end

  test "the last two members leaving at once leave no empty crew behind" do
    first = user!
    second = user!
    team = Teams::Crew.create!(user: first)
    Teams::Crew.join!(user: second, token: team.invite_token)

    outcomes = race(-> { Teams::Crew.leave!(user: User.find(first.id)) }, -> { Teams::Crew.leave!(user: User.find(second.id)) })

    assert(outcomes.all? { |kind, _| kind == :ok }, outcomes.map(&:last).inspect)
    assert_not Team.exists?(team.id)
  end
end
