module MerchTrack
  # What the dashboard card shows: this week's Status (the live boss's week, or the week that just ended while no newer
  # boss has started, for `afterglow_days` like the boss card), plus how many OTHER weeks have an earned reward still
  # waiting to be claimed. nil when there is no week with an item to show. Only the person's own numbers.
  class Panel
    attr_reader :status, :waiting

    def self.for(user, today:, now: Time.current, config: Config.current)
      boss = shown_boss(today)
      return unless boss && Track.item_for(boss, config: config)

      new(Status.for(user, boss, now: now, config: config), waiting_count(user, today, boss, now, config))
    end

    def self.shown_boss(today)
      Boss.covering(today).first ||
        Boss.where(ends_on: (today - Bosses::Config.current.afterglow_days)...today).chronological.last
    end
    private_class_method :shown_boss

    # Weeks already started (other than the one shown) that are earned and not claimed yet.
    def self.waiting_count(user, today, shown, now, config)
      bosses = Track.weeks(config: config).filter_map(&:boss).select { |boss| boss.starts_on <= today && boss.id != shown.id }
      return 0 if bosses.empty?

      claimed = MerchClaim.where(user_id: user.id, boss_id: bosses.map(&:id)).pluck(:boss_id)
      bosses.count { |boss| claimed.exclude?(boss.id) && Progress.for(user, boss, now: now, config: config).earned? }
    end
    private_class_method :waiting_count

    def initialize(status, waiting)
      @status = status
      @waiting = waiting
    end

    def waiting_text = "#{waiting} #{waiting == 1 ? 'reward is' : 'rewards are'} waiting from earlier weeks."
  end
end
