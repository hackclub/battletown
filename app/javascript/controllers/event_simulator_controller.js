import { Controller } from "@hotwired/stimulus"

// The development-only event simulator panel on the dashboard (app/views/dashboard/_simulator.html.erb). Two halves:
//
// - PREVIEW: the damage slider rewrites the boss's health bar, its two plates and the hidden summary in this browser only.
//   Nothing is sent anywhere; "restore live values" puts back what the page last showed from the server (and a reload does too).
// - SIMULATED PLAYERS: buttons that call Dev::SimulatorController (create players, ship, remove). Every answer carries fresh
//   numbers, which redraw the same bar, plates, summary and fighter circles, so the boss visibly takes damage without a reload.
//
// After every action that changed something the page shows it where you are looking: the health bar flashes and a number floats
// up from the boss ("-22.9 h", or "+3 players"). The message and the numbers sit in the panel's sticky "live" header.
//
// "auto" makes a few random players ship every N seconds, with a countdown beside it. It stops when the panel goes away
// (Turbo visit, or the page being cached for the back button), an action fails or the boss is defeated.
const MAX_FANS = 12 // the dashboard draws at most this many fighter circles
const MIN_SECONDS = 2
const MAX_SECONDS = 120
const MAX_HOURS = 100 // what the server allows for one ship (DevSimulator::MAX_HOURS); the server refuses more, so a bigger hit is only flagged here
const FLASH_MS = 600
const FLOAT_MS = 1200
const PREVIEW_MESSAGE = "preview only: nothing was saved"

export default class extends Controller {
  static targets = ["damage", "damageOutput", "count", "hoursMin", "hoursMax", "hitSize", "range", "auto", "seconds", "countdown", "clearDefeat", "message", "readout", "stat", "action"]
  static values = { statusUrl: String, playersUrl: String, shipUrl: String, resetUrl: String }

  connect() {
    this.busy = false
    this.cleanup()
    this.live = this.snapshot()
    this.showRange()
    this.refresh()
  }

  disconnect() {
    this.cleanup()
  }

  // Back to a quiet panel: auto off (no timer, no countdown), no flash on the health bar, no floating numbers left. Also run
  // before Turbo caches the page, so a back-button restore does not show auto ticked with nothing running.
  cleanup() {
    this.stopAuto()
    clearTimeout(this.flashTimer)
    document.querySelector(".stage__health--flash")?.classList.remove("stage__health--flash")
    document.querySelectorAll(".event-simulator__float").forEach((element) => element.remove())
  }

  // ---- preview (browser only) ----

  applyPreview(event) {
    event?.preventDefault()
    const damage = Math.min(100, Math.max(0, Math.round(Number(this.damageTarget.value) || 0)))
    this.damageOutputTarget.textContent = `${damage}%`
    const health = 100 - damage
    const text = damage === 0 ? "Full health" : `${health}% left`
    const summary = damage === 0 ? "Boss at full health, no hits yet this week." : damage === 100 ? "Boss defeated." : `Boss at ${health}% health.`
    this.paint({ health, text, summary })
    // A slider drag fires this on every step; say it once, not on each one (the message is a live region).
    if (event?.type !== "input" || this.messageTarget.textContent !== PREVIEW_MESSAGE) this.say(PREVIEW_MESSAGE)
  }

  restore() {
    this.paint(this.live)
    this.say("live values")
  }

  // ---- simulated players (writes to the dev database) ----

  createPlayers() {
    this.act(this.playersUrlValue, { count: this.countTarget.value })
  }

  ship(event) {
    const { mode, percent } = event.params
    this.act(this.shipUrlValue, this.shipBody(mode, percent))
  }

  reset() {
    this.stopAuto()
    this.act(this.resetUrlValue, { clear_defeat: this.clearDefeatTarget.checked })
  }

  // The timer beats once a second so the countdown can be drawn; every `interval` beats a few players ship.
  toggleAuto() {
    this.clearTimer()
    if (!this.autoTarget.checked) return

    if (this.live.state === "defeated") {
      this.stopAuto()
      this.say("The boss is already defeated, so auto has nothing to hit. Remove players with 'let this week's boss fall again' ticked first.")
      return
    }

    const seconds = Math.min(MAX_SECONDS, Math.max(MIN_SECONDS, Math.round(Number(this.secondsTarget.value) || 4)))
    this.secondsTarget.value = seconds
    this.interval = seconds
    this.remaining = seconds
    this.timer = setInterval(() => this.beat(), 1000)
    this.showCountdown()
    this.say(`auto on: a few random players ship every ${seconds} s`)
  }

  beat() {
    this.remaining -= 1
    if (this.remaining <= 0) {
      this.remaining = this.interval
      this.tick()
    }
    this.showCountdown()
  }

  showCountdown() {
    this.countdownTarget.textContent = `in ${this.remaining} s`
  }

  tick() {
    if (this.busy) return
    const few = 1 + Math.floor(Math.random() * 3)
    this.act(this.shipUrlValue, this.shipBody("count", null, few))
  }

  // Switch auto off: the timer and the checkbox.
  stopAuto() {
    this.clearTimer()
    if (this.hasAutoTarget) this.autoTarget.checked = false
  }

  clearTimer() {
    if (this.timer) clearInterval(this.timer)
    this.timer = null
    if (this.hasCountdownTarget) this.countdownTarget.textContent = ""
  }

  // ---- how big the next hits are ----

  hitFactor() {
    return Number(this.hitSizeTargets.find((radio) => radio.checked)?.value) || 1
  }

  // The hours range the next ships are drawn from: the two inputs times the hit size. Nothing is trimmed here: a product the server
  // refuses (over 100 h) goes as it is, so the server's message is what you see. Something that is not a number goes as typed too.
  hoursRange() {
    const factor = this.hitFactor()
    const scale = (raw) => {
      const number = Number(raw)
      return raw === "" || !Number.isFinite(number) ? raw : Math.round(number * factor * 100) / 100
    }
    return [scale(this.hoursMinTarget.value), scale(this.hoursMaxTarget.value)]
  }

  showRange() {
    const [min, max] = this.hoursRange()
    if (typeof min !== "number" || typeof max !== "number") {
      this.rangeTarget.textContent = ""
      return
    }
    const over = Math.max(min, max) > MAX_HOURS ? ` (over ${MAX_HOURS} h is refused)` : ""
    this.rangeTarget.textContent = `next ships: ${min} to ${max} h each${over}`
  }

  shipBody(mode, percent, count) {
    const [min, max] = this.hoursRange()
    const body = { mode, hours_min: min, hours_max: max }
    if (percent) body.percent = percent
    if (count) body.count = count
    return body
  }

  // ---- talking to the server ----

  async act(url, body) {
    if (this.busy) return
    this.setBusy(true)
    try {
      const data = await this.request(url, body)
      this.show(data.status)
      this.say(data.message)
      this.celebrate(data.status)
      if (this.autoTarget.checked && data.status.boss?.state === "defeated") {
        this.stopAuto()
        this.say(`${data.message} The boss is defeated, so auto is off.`)
      }
    } catch (error) {
      this.stopAuto()
      this.say(error.message)
    } finally {
      this.setBusy(false)
    }
  }

  async refresh() {
    try {
      const data = await this.request(this.statusUrlValue)
      this.show(data.status)
    } catch (error) {
      this.say(error.message)
    }
  }

  async request(url, body) {
    const options = { method: body ? "POST" : "GET", headers: { Accept: "application/json" }, credentials: "same-origin" }
    if (body) {
      options.headers["Content-Type"] = "application/json"
      options.headers["X-CSRF-Token"] = document.querySelector("meta[name='csrf-token']")?.content || ""
      options.body = JSON.stringify(body)
    }
    const response = await fetch(url, options)
    const data = await response.json().catch(() => ({}))
    if (!response.ok) throw new Error(data.error || `The server answered ${response.status}`)
    return data
  }

  // aria-disabled, not `disabled`: a disabled button loses keyboard focus, which would throw a keyboard user out of the panel
  // after every action (and every auto tick). act() already ignores a click while busy.
  setBusy(busy) {
    this.busy = busy
    this.actionTargets.forEach((button) => { button.setAttribute("aria-disabled", String(busy)) })
  }

  say(text) {
    this.messageTarget.textContent = text
  }

  // ---- feedback next to the boss ----

  // Flash the bar and float a number, when the action changed anything (a ship that hit nothing only says so in the message).
  celebrate(status) {
    const last = status.last || {}
    const hit = Number(last.hit_seconds) || 0
    const created = Number(last.created) || 0
    if (hit > 0 || created > 0 || last.removed > 0 || last.cleared_defeat > 0) this.flash()
    if (hit > 0) this.float(`-${this.hours(hit)}`)
    else if (created > 0) this.float(created === 1 ? "+1 player" : `+${created} players`)
  }

  // A brief outline and glow on the page's health bar (the CSS drops all motion for reduced motion).
  flash() {
    const bar = document.querySelector(".stage__health")
    if (!bar) return
    bar.classList.add("stage__health--flash")
    clearTimeout(this.flashTimer)
    this.flashTimer = setTimeout(() => bar.classList.remove("stage__health--flash"), FLASH_MS)
  }

  // A decorative number that rises from the boss and removes itself (the CSS fades it, or holds it still for reduced motion).
  float(text) {
    const arena = document.querySelector(".stage__arena")
    if (!arena) return
    const element = document.createElement("span")
    element.className = "event-simulator__float"
    element.setAttribute("aria-hidden", "true")
    element.textContent = text
    arena.appendChild(element)
    setTimeout(() => element.remove(), FLOAT_MS)
  }

  // ---- drawing the numbers ----

  // Redraw the page and the panel from the server's numbers (Dev::SimulatorController's `status`).
  show(status) {
    const boss = status.boss
    if (boss) {
      this.paint({ health: boss.health_percent, text: boss.health_text, summary: boss.summary, arena: boss.arena_text, state: boss.state })
      this.live = this.snapshot()
      this.fans(status.people_coded_today)
    }
    this.stats(status)
  }

  // Put a health value into the bar, the second plate and the visually hidden sentences. Missing parts of the page are skipped
  // (a page rendered with no boss has none of them: reload after the boss appears).
  paint({ health, text, summary, arena, state }) {
    const bar = document.getElementById("stage-boss-health")
    if (bar) {
      bar.value = health
      bar.textContent = text
    }
    this.text(".stage__health .progress__text", text)
    this.text(".stage__plate:not(.stage__plate--name) .stage__plate-text", text)
    this.text("#stage-boss-summary", summary)
    if (arena !== undefined) this.text(".stage__arena > p.visually-hidden", arena)
    if (state) this.setState(state)
  }

  // What the page shows right now, so "restore live values" has something to restore.
  snapshot() {
    const read = (selector) => document.querySelector(selector)?.textContent.trim() ?? ""
    const bar = document.getElementById("stage-boss-health")
    return {
      health: bar ? Number(bar.value) : 100,
      text: read(".stage__plate:not(.stage__plate--name) .stage__plate-text"),
      summary: read("#stage-boss-summary"),
      arena: read(".stage__arena > p.visually-hidden"),
      state: this.currentState()
    }
  }

  text(selector, value) {
    const element = document.querySelector(selector)
    if (element && value !== undefined) element.textContent = value
  }

  currentState() {
    const stage = document.querySelector(".stage")
    const match = stage && [...stage.classList].find((name) => /^stage--(in-progress|defeated|escaped|none)$/.test(name))
    return match ? match.replace("stage--", "").replaceAll("-", "_") : null
  }

  setState(state) {
    const stage = document.querySelector(".stage")
    if (!stage) return
    stage.classList.remove("stage--in-progress", "stage--defeated", "stage--escaped", "stage--none")
    stage.classList.add(`stage--${state.replaceAll("_", "-")}`)
  }

  // One circle per person who coded today, at most MAX_FANS, like the page does.
  fans(people) {
    const crowd = document.querySelector(".stage__crowd")
    if (!crowd) return
    const wanted = Math.min(Math.max(Number(people) || 0, 0), MAX_FANS)
    while (crowd.children.length > wanted) crowd.lastElementChild.remove()
    while (crowd.children.length < wanted) {
      const fan = document.createElement("li")
      fan.className = "stage__fan"
      crowd.appendChild(fan)
    }
  }

  stats(status) {
    const boss = status.boss
    const values = {
      boss: boss ? boss.name : "no boss today",
      damage: boss ? this.hours(boss.damage_seconds) : "-",
      health: boss ? boss.health_text : "-",
      togo: boss ? (boss.hours_to_go_text || "-") : "-",
      players: status.players,
      coded: status.people_coded_today
    }
    if (this.hasReadoutTarget) this.readoutTarget.textContent = boss ? `${boss.name} · ${boss.health_text}` : "no boss today"
    this.statTargets.forEach((element) => {
      const value = values[element.dataset.stat]
      element.textContent = value === undefined ? "-" : String(value)
    })
  }

  hours(seconds) {
    return `${(seconds / 3600).toFixed(1)} h`
  }
}
