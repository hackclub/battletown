module Analytics
  # Stores today's aggregates in analytics_daily_snapshots (one row per key per day, upserted, so the hourly job keeps today current and a finished
  # day keeps the last value it had). Numbers only: no user id, no name, nothing that points at a person. Staff, simulated and listed test players
  # are left out (User.analytics_included). The history is the point: deleting a person or changing a ship's status rewrites anything recomputed
  # from the live tables, but a stored row does not move. Nothing is ever deleted from the table.
  #
  # The numbers are stored exactly, small cells included: the table is read only by operators, and a "<5" written here could never be turned back
  # into the number. Anything that shows them to a reader applies the small-cell rule when it displays them (Analytics::Report.suppress).
  #
  # The hourly run is at :45, so the last run of a UTC day stops 15 minutes short of midnight. The first run after midnight therefore finishes
  # the day before (finalize_previous_day): it rewrites that day's flows for the whole day and leaves its gauges as the last run stored them.
  #
  # Keys (a dot-separated lowercase path, at most 60 characters):
  #   funnel.<step>.ever      people who ever reached the step (AdminMetrics::FUNNEL_STEPS; each step on its own)
  #   people.total, people.active, people.site_day, signups, hours.coded_seconds
  #   ships.<status>, ships.pending_review, ships.oldest_wait_hours, orders.<status>
  #   coins.issued.<kind>, coins.spent.<kind>               coins over the day
  #   boss.damage_seconds                                   the boss whose week it is
  #   visits.total, visits.signed_up                        sessions that began today, and those whose person signed up in them
  #   notifications.<channel>.<kind>.<status>               rows due today
  #   hackatime.healthy, .needs_reconnect, .never_synced
  #   events.total, events.<name>                           events today
  #   snapshot.final                                        1 once the day's flows were finished after midnight (a day without it is still open)
  # Gauges (funnel, ships, orders, hackatime, boss, people.total) describe the moment the job ran, so only a run for today writes them; flows
  # (people.active, hours, signups, coins, visits, events, notifications) cover the UTC day.
  class Snapshot
    FINAL_KEY = "snapshot.final".freeze
    Result = Data.define(:day, :keys)

    # Finishes yesterday's flows once (the day's last hourly run stops at :45). Only a day the job already ran for; nil when there is nothing to do.
    def self.finalize_previous_day(today: Time.current.utc.to_date)
      day = today - 1
      stored = AnalyticsDailySnapshot.where(day: day)
      return if !stored.exists? || stored.exists?(key: FINAL_KEY)

      call(day: day)
    end

    def self.call(day: Time.current.utc.to_date) = new(day).call

    def initialize(day)
      @day = day
      @window = day.in_time_zone("UTC")...(day + 1).in_time_zone("UTC")
      @open = day >= Time.current.utc.to_date
      @rows = {}
    end

    def call
      metrics = AdminMetrics.new(today: @day, minimum_seconds: Game::Config.current.quick_seconds)
      people(metrics)
      coins
      visits
      notifications
      events
      if @open
        funnel(metrics)
        ships
        orders
        boss
        hackatime
      else
        total(FINAL_KEY, 1)
      end
      write
    end

    private

    def users = User.analytics_included

    def measured = users.select(:id)

    def total(key, value) = @rows[key] = value.to_i

    def funnel(metrics)
      AdminMetrics::FUNNEL_STEPS.keys.zip(metrics.funnel).each { |step, row| total("funnel.#{step}.ever", row.count) }
    end

    def people(metrics)
      today = metrics.daily.last
      total("people.total", users.count) if @open
      total("people.active", today.active_users)
      total("hours.coded_seconds", today.seconds)
      total("people.site_day", AnalyticsSiteDay.where(day: @day).count)
      total("signups", users.where(created_at: @window).count)
    end

    def ships
      mine = Ship.where(user_id: measured)
      status_cells("ships", mine, Ship::STATUSES)
      waiting = mine.where(status: "submitted")
      total("ships.pending_review", waiting.count)
      oldest = waiting.minimum(:submitted_at)
      total("ships.oldest_wait_hours", oldest ? ((Time.current - oldest) / 1.hour).floor : 0)
    end

    def orders = status_cells("orders", Order.where(user_id: measured), Order::STATUSES)

    # One key per status (a status nobody has is a 0): the number of rows.
    def status_cells(prefix, scope, statuses)
      found = scope.group(:status).count
      statuses.each { |status| total("#{prefix}.#{status}", found.fetch(status, 0)) }
    end

    def coins
      rows = CoinTransaction.where(user_id: measured, created_at: @window).group(:kind, Arel.sql("amount > 0")).pluck(:kind, Arel.sql("amount > 0"), Arel.sql("SUM(ABS(amount))"))
      rows.each { |kind, credit, sum| total("coins.#{credit ? 'issued' : 'spent'}.#{kind}", sum) }
    end

    def boss
      current = Boss.without_art_content.covering(@day).first
      return unless current

      seconds = Bosses::Damage.ships_in(current).where(user_id: measured).sum(Arel.sql(Bosses::Damage::SECONDS))
      total("boss.damage_seconds", Bosses::BossMath.damage(seconds))
    end

    def visits
      today = AnalyticsVisit.where(started_at: @window)
      total("visits.total", today.count)
      total("visits.signed_up", today.joins(:user).where("users.created_at >= analytics_visits.started_at").count)
    end

    def notifications
      Notification.where(user_id: measured, due_at: @window).group(:channel, :kind, :status).count
                  .each { |(channel, kind, status), count| total("notifications.#{channel}.#{kind}.#{status}", count) }
    end

    def hackatime
      connections = HackatimeConnection.where(user_id: measured)
      people = connections.count
      broken = connections.where(needs_reconnect: true).count
      unsynced = connections.where(needs_reconnect: false, last_synced_at: nil).count
      total("hackatime.needs_reconnect", broken)
      total("hackatime.never_synced", unsynced)
      total("hackatime.healthy", people - broken - unsynced)
    end

    def events
      today = AnalyticsEvent.where(occurred_at: @window)
      total("events.total", today.count)
      today.group(:name).count.each { |name, count| total("events.#{name}", count) }
    end

    # One upsert for the day: a rerun overwrites today's numbers and never touches another day's.
    def write
      AnalyticsDailySnapshot.upsert_all(@rows.map { |key, value| { day: @day, key: key, value: value } }, unique_by: %i[day key])
      Result.new(day: @day, keys: @rows.size)
    end
  end
end
