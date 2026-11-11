require "test_helper"
require_relative "../../support/notifications_helper"

# Real concurrency needs real, committed transactions on separate connections, so this class opts out of the
# per-test transaction and cleans up after itself (deleting the users cascades to their notifications).
class Notifications::DispatcherConcurrencyTest < ActiveSupport::TestCase
  include NotificationsHelper

  self.use_transactional_tests = false

  DUE = Time.utc(2026, 11, 11, 18, 30)
  RUN_AT = DUE + 1.minute

  class LockedAdapter < Notifications::Slack::Adapter
    attr_reader :slack_ids

    def initialize
      @slack_ids = []
      @mutex = Mutex.new
    end

    def delivers? = true

    def deliver_dm(slack_id:, text:)
      sleep 0.01 # widen the window in which a second dispatcher could grab the same row
      @mutex.synchronize { @slack_ids << slack_id }
      Notifications::Slack::Result.success
    end
  end

  setup do
    @users = Array.new(12) { create_user }
    @users.each { |user| Notifications::Scheduler.schedule_next(user, now: DUE - 6.hours) }
  end

  teardown { User.where(id: @users.map(&:id)).delete_all }

  def dispatch(adapter, limit: 100)
    ActiveRecord::Base.connection_pool.with_connection do
      with_env("NOTIFICATIONS_ENABLED" => "true") do
        Notifications::Dispatcher.run(now: RUN_AT, limit: limit, adapter: adapter, config: Notifications::Config.current.with(batch_size: 3))
      end
    end
  end

  test "several dispatchers at once send every reminder exactly once" do
    adapter = LockedAdapter.new
    4.times.map { Thread.new { dispatch(adapter) } }.each(&:join)

    assert_equal @users.map(&:slack_id).sort, adapter.slack_ids.sort
    assert_equal 12, Notification.where(user_id: @users.map(&:id), status: "sent").count
    assert_equal 12, Notification.where(user_id: @users.map(&:id), attempts: 1).count
  end

  test "a row locked by another worker is skipped, not waited for and not double sent" do
    locked = Notification.find_by!(user: @users.first, status: "pending")
    holding = Queue.new
    release = Queue.new
    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Notification.transaction do
          Notification.lock("FOR UPDATE").find(locked.id)
          holding << true
          release.pop
        end
      end
    end
    holding.pop

    adapter = LockedAdapter.new
    # Must return promptly, handling the 11 rows that are not locked (without SKIP LOCKED it would wait on the lock).
    Timeout.timeout(15) { dispatch(adapter) }

    assert_equal 11, adapter.slack_ids.size
    assert_not_includes adapter.slack_ids, @users.first.slack_id
    assert locked.reload.pending?
    assert_equal 0, locked.attempts

    release << true
    holder.join

    dispatch(adapter) # now the released row goes out, once
    assert_equal 12, adapter.slack_ids.size
    assert_equal 1, adapter.slack_ids.count(@users.first.slack_id)
  end
end
