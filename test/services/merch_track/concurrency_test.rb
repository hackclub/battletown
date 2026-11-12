require "test_helper"
require_relative "../../support/merch_helper"

# Real threads on real connections, so these cannot run inside a rolled-back transaction. Each test builds its own
# user and boss, and removes them (the database cascades to the claims) at the end.
class MerchTrack::ConcurrencyTest < ActiveSupport::TestCase
  include MerchHelper

  self.use_transactional_tests = false

  setup do
    @boss = Boss.create!(name: "Race boss", art_key: "placeholder", starts_on: Date.new(2031, 3, 7), ends_on: Date.new(2031, 3, 13), hp_seconds: HOUR)
    @user = verified!(build_user(created_on: Date.new(2031, 3, 1)))
    5.times { |offset| goal_day(@user, @boss.starts_on + offset) }
    approved_ship!(@user)
    Flipper.enable(:merch_track)
  end

  teardown do
    Flipper.disable(:merch_track)
    User.where(id: @user.id).delete_all
    Boss.where(id: @boss.id).delete_all
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

  test "a double click from two tabs at once makes exactly one claim" do
    now = Time.utc(2031, 3, 14, 12)
    claim = -> { MerchTrack::Claim.call(user: User.find(@user.id), boss: Boss.find(@boss.id), now: now) }
    outcomes = race(claim, claim, claim)

    assert_equal [ :ok ] * 3, outcomes.map(&:first), outcomes.inspect
    assert_equal 1, outcomes.count { |_, result| result.created }
    assert_equal 1, outcomes.map { |_, result| result.claim.id }.uniq.size
    assert_equal 1, MerchClaim.where(user_id: @user.id).count
  end
end
