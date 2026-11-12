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
    # catches up.
    def self.for_date(date)
      Boss.covering(date).where(defeated_at: nil).find_each { |boss| call(boss) }
    rescue StandardError => error
      Rails.logger.error("bosses.check_defeat failed error=#{error.class}")
    end

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
