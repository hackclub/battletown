# The boss stage's live updates (Bosses::Live): one stream per boss week, the same for every viewer, never per person. What goes out is
# Bosses::Presenter#public_payload (health, damage, the fighters in the shape GET /boss/fighters serves them, with nobody marked `you`).
# Rejected while the Flipper kill switch `live_updates_paused` is on, and when there is no boss to follow; the page then keeps asking every
# 30 seconds (boss_fighters_controller.js). The connection has already turned away anyone who is not signed in and onboarded.
class BossStageChannel < ApplicationCable::Channel
  def subscribed
    boss = Bosses::Live.enabled? && Bosses::Live.current_boss
    return reject unless boss

    stream_from Bosses::Live.stream_for(boss)
  end
end
