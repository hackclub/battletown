module DevSimulator
  # What the panel shows after every action: aggregates only (a boss, sums and counts, the people who coded and shipped in the last
  # 24 hours), never a name or an id. `last` is the counts of the action that just ran (merged in by the controller), nil for a
  # plain refresh.
  #
  # The boss numbers come from the same presenter as the dashboard card, so the page and the panel always say the same thing.
  class Status
    def self.call(**args) = new(**args).call

    def initialize(user:, today: Hours::Days.today("UTC"), last: nil, now: Time.current)
      @user = user
      @today = today
      @last = last
      @now = now
    end

    def call
      DevSimulator.check_local_database!
      {
        boss: boss_numbers,
        players: DevSimulator.players.count,
        people_coded: presenter.fighter_count,
        people_shipped: presenter.shipper_count,
        simulated_minutes_24h: HourEntry.where(user_id: sim_ids).where("recorded_at > ?", @now - Bosses::Fighters::WINDOW).sum(:seconds) / 60,
        simulated_ships_this_week: boss ? Bosses::Damage.ships_in(boss).where(user_id: sim_ids).count : 0,
        last: @last
      }
    end

    private

    def sim_ids = DevSimulator.players.select(:id)

    def presenter = @presenter ||= Bosses::Presenter.new(user: @user, today: @today, now: @now)

    # The boss whose week covers today, a UTC date (what the damage is counted for); nil between bosses.
    def boss = @boss ||= Boss.without_art_content.covering(@today).first

    def boss_numbers
      return unless presenter.boss?

      state = presenter.state
      { name: presenter.boss_name, state: state.to_s, damage_seconds: boss ? Bosses::Damage.for(boss) : 0,
        health_percent: presenter.health_percent, health_text: presenter.health_text, hours_to_go_text: presenter.hours_to_go_text,
        summary: presenter.summary, community_text: presenter.community_text }
    end
  end
end
