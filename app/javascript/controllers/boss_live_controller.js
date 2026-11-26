import { Controller } from "@hotwired/stimulus"
import { cable } from "@hotwired/turbo-rails"

// Pushes from the server to the boss stage (app/views/dashboard/_stage.html.erb): when anyone ships, who is fighting changes or the boss
// falls, Bosses::Live broadcasts the new stage on BossStageChannel and this controller hands it to boss_fighters_controller.js, which
// draws it in place (circles that stay are not rebuilt, so their animations keep running). It adds nothing to what the stage already
// shows everyone: the message has no `you`, no personal sentence and nothing private.
//
// This page's own parts are put back before drawing: the viewer's circle is marked `you` (found by the key the page was rendered with, the
// same words as Bosses::Fighters::Circle#title and #label) and the arena sentence keeps the viewer's own damage. The plan and the ship
// button are not in the message at all.
//
// The poll in boss_fighters_controller.js stays the fallback: it is told when the socket is up ("boss-live:state" live: true, the poll
// slows to a reconcile every couple of minutes) and when it is not (down, rejected, the kill switch `live_updates_paused` sent a
// "paused" message, no WebSocket): then it asks every 30 seconds as before. Action Cable reconnects by itself; every reconnect asks once
// for the current stage, since a message sent while the socket was down is not replayed.
//
// Everything goes in as text and class names, never as markup (the draw code uses textContent).
export default class extends Controller {
  static values = { ownKey: String }

  connect() {
    this.stopped = false
    this.opened = false
    this.latest = 0
    if (typeof WebSocket === "undefined" || !cable?.subscribeTo) return this.state(false)
    this.subscribe()
  }

  disconnect() {
    this.stopped = true
    this.subscription?.unsubscribe()
    this.subscription = null
  }

  async subscribe() {
    try {
      const subscription = await cable.subscribeTo({ channel: "BossStageChannel" }, {
        connected: () => this.connected(),
        disconnected: () => this.state(false),
        rejected: () => this.giveUp(),
        received: (message) => this.received(message)
      })
      if (this.stopped) subscription.unsubscribe()
      else this.subscription = subscription
    } catch (error) {
      this.state(false)
    }
  }

  connected() {
    if (this.stopped) return
    this.state(true, this.opened) // not the first time: whatever was sent while the socket was down is gone, so ask once
    this.opened = true
  }

  // The server will not take this page's subscription (kill switch on, no boss): poll for good.
  giveUp() {
    this.stopped = true
    this.state(false)
  }

  received(message) {
    if (this.stopped || !message || typeof message !== "object") return
    if (message.type === "paused") return this.giveUp()
    if (!Array.isArray(message.fighters)) return
    const at = Number(message.at) || 0
    if (at && at < this.latest) return // an older message that arrived late
    this.latest = Math.max(this.latest, at)
    this.dispatch("draw", { detail: this.personalize(message) })
  }

  state(live, catchUp = false) {
    this.dispatch("state", { detail: { live, catchUp } })
  }

  personalize(message) {
    const damageText = this.element.dataset.damageText || ""
    const own = this.ownKeyValue
    return {
      ...message,
      damage_text: damageText,
      arena_text: [message.community_text, damageText, message.outcome_text].filter(Boolean).join(" "),
      fighters: message.fighters.map((fighter) => (own && fighter.key === own ? this.asYou(fighter) : fighter))
    }
  }

  // The viewer's own circle: the same words as Bosses::Fighters::Circle (title "You (name)", the label, the profile hint).
  asYou(fighter) {
    const title = fighter.title === "A player" ? "You" : `You (${fighter.title})`
    const hint = fighter.path ? "Click to see your profile" : null
    return { ...fighter, you: true, title, hint, label: `${title}: ${fighter.detail}, ${fighter.status}.${hint ? ` ${hint}.` : ""}` }
  }
}
