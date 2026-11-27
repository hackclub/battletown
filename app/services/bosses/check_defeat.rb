module Bosses
  # Marks a boss defeated when its damage (the hours on the ships submitted in its week) has reached its health. Safe to
  # call as often as you like, from any number of threads:
  #
  # - the work happens inside a row lock on the boss (read without its picture bytes, which `boss.with_lock` would reload), so
  #   concurrent callers take turns;
  # - the write is a conditional UPDATE ... WHERE defeated_at IS NULL, so `defeated_at` is set exactly once;
  # - nothing here ever clears it, so a later correction that lowers the damage cannot un-defeat the boss.
  #
  # Returns true only for the call that actually recorded the defeat.
  class CheckDefeat
    def self.call(boss) = new(boss).call

    # Called after a ship is submitted (the only change that can raise the damage; a withdrawal, approval or rejection can only
    # lower it, and a defeat is never cleared, so those do not call this): checks the boss whose week the ship's `submitted_at`
    # falls in (UTC date, see Bosses::Damage). The ship change has already committed, so a failure here must never fail it;
    # the damage is derived, not stored, so the next ship catches up.
    def self.for_ship(ship)
      return unless ship.submitted_at

      date = ship.submitted_at.utc.to_date
      Boss.without_art_content.where(defeated_at: nil).covering(date).find_each { |boss| call(boss) }
    rescue StandardError => error
      Rails.logger.error("bosses.check_defeat failed error=#{error.class}")
    end

    def initialize(boss)
      @boss = boss
    end

    def call
      Boss.transaction do
        locked = Boss.without_art_content.lock.find(@boss.id)
        next false if locked.defeated_at.present?
        next false unless BossMath.defeated?(Damage.for(locked), locked.hp_seconds)

        now = Time.current
        recorded = Boss.where(id: locked.id, defeated_at: nil).update_all(defeated_at: now, updated_at: now) == 1
        refresh(Boss.without_art_content.find(locked.id)) if recorded
        recorded
      end
    end

    private

    # Shows the caller's record the defeat, without reloading it (a reload would read the picture bytes).
    def refresh(fresh)
      @boss.defeated_at = fresh.defeated_at
      @boss.updated_at = fresh.updated_at
      @boss.clear_attribute_changes(%w[defeated_at updated_at])
    end
  end
end
