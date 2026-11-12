require "test_helper"
require_relative "../../support/coins_helper"
require_relative "../../support/ships_test_support"

# Real threads on real connections, so these cannot run inside a rolled-back transaction. Each test builds its own user
# and deletes it at the end (the database cascades to projects, ships, hours and coins).
class Ships::ConcurrencyTest < ActiveSupport::TestCase
  include CoinsHelper
  include ShipsTestSupport

  self.use_transactional_tests = false

  D = ->(day) { Date.new(2026, 11, day) }
  NOW = Time.utc(2026, 11, 10, 12)

  setup do
    @user = build_user(created_on: D[1])
    @reviewer = build_user
    @project = make_project(@user)
    (1..3).each { |day| code(@user, D[day], HOUR) }
  end

  teardown { User.where(id: [ @user.id, @reviewer.id ]).delete_all }

  # Runs the blocks at the same moment on separate connections; each outcome is [:ok, value] or [:error, exception].
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

  def approve_block(ship_id)
    lambda do
      ship = Ship.find(ship_id)
      Ships::Approve.call(ship: ship, reviewer: User.find(@reviewer.id), approved_seconds: ship.coded_seconds, now: NOW)
    end
  end

  test "three admins approving the same ship at once credit it exactly once" do
    ship = submit_ship(@project)
    outcomes = race(approve_block(ship.id), approve_block(ship.id), approve_block(ship.id))

    assert(outcomes.all? { |kind, _| kind == :ok }, outcomes.map(&:last).inspect)
    assert_equal 1, outcomes.count { |_, result| result.approved? }
    assert_equal 2, outcomes.count { |_, result| result.unavailable? }
    assert_equal 1, CoinTransaction.where(user_id: @user.id, kind: "ship_approval").count
    assert_equal 1, CoinTransaction.where(user_id: @user.id, kind: "streak_bonus").count
    assert_equal 32, Coins::Balance.total(@user)
    assert_equal "approved", ship.reload.status
  end

  test "an approval racing a withdrawal ends in exactly one consistent state" do
    ship = submit_ship(@project)
    outcomes = race(approve_block(ship.id), -> { Ships::Withdraw.call(ship: Ship.find(ship.id)) })

    assert(outcomes.all? { |kind, _| kind == :ok }, outcomes.map(&:last).inspect)
    ship.reload
    credits = CoinTransaction.where(user_id: @user.id).count
    if ship.status == "approved"
      assert_equal 2, credits
    else
      assert_equal "withdrawn", ship.status
      assert_equal 0, credits
    end
  end

  test "an approval racing a rejection ends in exactly one decision" do
    ship = submit_ship(@project)
    outcomes = race(approve_block(ship.id), -> { Ships::Reject.call(ship: Ship.find(ship.id), reviewer: User.find(@reviewer.id), reason: "No") })

    assert(outcomes.all? { |kind, _| kind == :ok }, outcomes.map(&:last).inspect)
    ship.reload
    assert_includes %w[approved rejected], ship.status
    assert_equal(ship.status == "approved" ? 2 : 0, CoinTransaction.where(user_id: @user.id).count)
  end

  test "two simultaneous submits of one project open a single ship" do
    submit = lambda do
      Ships::Submit.call(project: Project.find(@project.id), attributes: ship_attrs, submit: true)
    end
    outcomes = race(submit, submit, submit)

    assert_equal 1, outcomes.count { |kind, _| kind == :ok }
    failures = outcomes.select { |kind, _| kind == :error }.map(&:last)
    assert(failures.all? { |error| error.is_a?(Ships::Submit::AlreadyOpen) }, failures.inspect)
    assert_equal 1, Ship.where(project_id: @project.id).count
  end
end
