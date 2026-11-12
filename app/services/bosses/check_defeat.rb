module Bosses
  # Marks a boss defeated when its damage has reached its health. Safe to call as often as you like, from any
  # number of threads:
  #
  # - the work happens inside `boss.with_lock`, so concurrent callers take turns;
  # - the write is a conditional UPDATE ... WHERE defeated_at IS NULL, so `defeated_at` is set exactly once;
  # - nothing here ever clears it, so a later correction that lowers the damage cannot un-defeat the boss.
  #
  # Returns true only for the call that actually recorded the defeat.
  class CheckDefeat
    def self.call(boss) = new(boss).call

    # Called from HourEntry after commit: checks every boss whose week covers that local date. The ledger write has
    # already committed, so a failure here must never fail it; the damage is derived, not stored, so the next entry
    # catches up. Inside `batched` the date is only noted and checked when the batch ends.
    def self.for_date(date)
      pending = ActiveSupport::IsolatedExecutionState[:bosses_check_defeat_dates]
      return pending << date if pending

      check_dates([ date ])
    end

    # Defers the per-entry checks made inside the block to one check per boss when the outermost block ends (also
    # when it raises: entries committed before the error still count). Summing a boss week costs the same for one
    # entry as for thousands, so bulk writers (Hours::Sync, the hours:import and hackatime:sync tasks) wrap their
    # loops in this instead of summing the week again after every entry. Per thread; nesting is a no-op.
    def self.batched
      return yield if ActiveSupport::IsolatedExecutionState[:bosses_check_defeat_dates]

      ActiveSupport::IsolatedExecutionState[:bosses_check_defeat_dates] = Set.new
      begin
        yield
      ensure
        dates = ActiveSupport::IsolatedExecutionState.delete(:bosses_check_defeat_dates)
        check_dates(dates)
      end
    end

    def self.check_dates(dates)
      return if dates.empty?

      Boss.where(defeated_at: nil).where(starts_on: ..dates.max, ends_on: dates.min..).find_each do |boss|
        call(boss) if dates.any? { |date| boss.range.cover?(date) }
      end
    rescue StandardError => error
      Rails.logger.error("bosses.check_defeat failed error=#{error.class}")
    end
    private_class_method :check_dates

    def initialize(boss)
      @boss = boss
    end

    def call
      @boss.with_lock do
        next false if @boss.defeated_at.present?
        next false unless BossMath.defeated?(Damage.for(@boss), @boss.hp_seconds)

        now = Time.current
        recorded = Boss.where(id: @boss.id, defeated_at: nil).update_all(defeated_at: now, updated_at: now) == 1
        @boss.reload if recorded
        recorded
      end
    end
  end
end
