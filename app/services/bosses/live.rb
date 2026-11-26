module Bosses
  # Pushes the boss stage to every open dashboard (BossStageChannel, boss_live_controller.js) so a ship, a change in who is fighting or the
  # boss falling shows within seconds instead of at the next 30-second poll. The poll stays: it is the fallback whenever the socket is down
  # or the kill switch is on (Flipper `live_updates_paused`, ON means paused: every page is told and goes back to asking).
  #
  #   Bosses::Live.ship_submitted(ship, defeated: true)   # Ships::Submit, after its transaction has committed
  #   Bosses::Live.hours_changed                          # HourEntry after_commit: coded time arrived, so the fighters may have changed
  #
  # What goes out is Presenter#public_payload for ONE stream per boss week ("boss_stage:<boss id>"): only what the stage already shows to
  # every signed-in player, with nobody marked `you` and no personal sentence. Each page keeps its own plan, ship button and totals.
  #
  # Coalescing: at most one broadcast per THROTTLE per boss (a cache lock, shared by every process and replica, because the hours sync can
  # credit hundreds of people in seconds). A change that arrives inside the window is not lost: it marks the boss dirty and schedules ONE
  # trailing broadcast TRAILING_DELAY later (BroadcastBossStageJob), which carries everything that changed meanwhile. A defeat skips the
  # lock (it is rare and everybody wants to see it). A process that ends before its trailing job runs (the hourly sync task) flushes it
  # itself with `flush_pending`.
  #
  # Nothing here is ever allowed to break what called it: a failure is logged by class name only and announced as
  # "boss_live_failed.battletown"; the ship, the credit and the sync carry on.
  module Live
    THROTTLE = 5.seconds
    TRAILING_DELAY = 6.seconds
    # How long a "changes are waiting" mark lasts if its job never runs (a restart): afterwards the next change schedules a new one.
    DIRTY_FOR = 10.seconds
    PAUSED_MESSAGE = { type: "paused" }.freeze

    module_function

    # Live updates are on unless the kill switch is.
    def enabled? = !Features.enabled?(:live_updates_paused)

    def stream_for(boss) = "boss_stage:#{boss.id}"

    # The boss the stage shows today (the UTC date, as the dashboard and Bosses::Damage pick it): the one whose week it is, else one that
    # ended within the afterglow. Same choice as Bosses::Presenter, read without the picture.
    def current_boss(today = Hours::Days.today("UTC"))
      Boss.without_art_content.covering(today).first ||
        Boss.without_art_content.where(ends_on: (today - Config.current.afterglow_days)...today).order(ends_on: :desc).first
    end

    # A ship was submitted (and `defeated`: that submission brought the boss down).
    def ship_submitted(ship, defeated: false)
      changed(force: defeated) if ship&.submitted_at
    end

    # Coded time was written to the ledger: the people fighting may be other people now.
    def hours_changed = changed

    # Something on the stage changed: broadcast it now, or, inside the throttle window, once more a moment later.
    def changed(force: false)
      boss = current_boss
      return unless boss

      if force
        lock(boss)
        publish(boss)
      elsif lock(boss, only_if_free: true)
        publish(boss)
      else
        defer(boss)
      end
    rescue StandardError => error
      failed(error)
    end

    # The trailing broadcast (BroadcastBossStageJob).
    def flush(boss_id)
      boss = Boss.without_art_content.find_by(id: boss_id)
      return unless boss

      Rails.cache.delete(dirty_key(boss))
      lock(boss)
      publish(boss)
    rescue StandardError => error
      failed(error)
    end

    # For a process that is about to end (lib/tasks/hackatime.rake): send what is waiting for its trailing job, then let the write queue of the
    # cable adapter drain, which Solid Cable fills on a background thread.
    def flush_pending
      boss = current_boss
      flush(boss.id) if boss && Rails.cache.read(dirty_key(boss))
      ActionCable.server.pubsub.shutdown
    rescue StandardError => error
      failed(error)
    end

    # Sends the stage as it is now (or, with the kill switch on, tells the pages to go back to polling).
    def publish(boss)
      unless enabled?
        ActionCable.server.broadcast(stream_for(boss), PAUSED_MESSAGE)
        return
      end

      now = Time.current
      Fighters.forget_for(boss, now: now) # the broadcast must not repeat a snapshot cached up to 20 seconds ago
      payload = Presenter.new(user: nil, today: Hours::Days.today("UTC", now: now), now: now).public_payload
      ActionCable.server.broadcast("boss_stage:#{payload[:boss_id]}", payload.merge(at: (now.to_f * 1000).to_i)) if payload[:boss_id]
    end

    # true for the one caller that takes the window (or, without `only_if_free`, always: it just starts a new window).
    def lock(boss, only_if_free: false)
      only_if_free ? Rails.cache.write(lock_key(boss), 1, unless_exist: true, expires_in: THROTTLE) : Rails.cache.write(lock_key(boss), 1, expires_in: THROTTLE)
    end

    # Marks the boss dirty and schedules the trailing broadcast, once per window.
    def defer(boss)
      return unless Rails.cache.write(dirty_key(boss), 1, unless_exist: true, expires_in: DIRTY_FOR)

      BroadcastBossStageJob.set(wait: TRAILING_DELAY).perform_later(boss.id)
    end

    def lock_key(boss) = "bosses/live/lock/#{boss.id}"

    def dirty_key(boss) = "bosses/live/dirty/#{boss.id}"

    def failed(error)
      Rails.logger.error("bosses.live failed error=#{error.class}")
      ActiveSupport::Notifications.instrument("boss_live_failed.battletown", error_class: error.class.name)
      nil
    end
    private_class_method :lock, :defer, :lock_key, :dirty_key, :failed
  end
end
