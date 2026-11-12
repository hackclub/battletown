import { Controller } from "@hotwired/stimulus"

const SOUND_KEY = "battletown:plinko-sound" // "off" when the player muted it; anything else (or nothing) means on
const MASTER_GAIN = 0.18
const STEP_MS = 190 // time to travel from one row of pegs to the next
const SETTLE_MS = 320 // time to drop into the slot
const SILENT = 0.0001

// Plays back a drop the server already decided: POST /plinko/drops answers with the route (0 = left, 1 = right per
// row), the slot and the points, and this only draws the board and animates that route. Nothing the browser does can
// change the outcome. Reduced motion skips the animation. Sound is synthesised (no files), on by default, can be muted
// (remembered in localStorage) and only ever starts from the click on "Drop a ball" (a user gesture).
export default class extends Controller {
  static targets = [ "canvas", "drop", "status", "balls", "ballsLabel", "today", "week", "total", "rank", "sound", "next" ]
  static values = { url: String, rows: Number, points: Array, balls: Number }

  connect() {
    this.muted = this.storedMuted()
    this.landed = null
    this.ball = null
    this.pendingKey = null
    this.busy = false
    this.renderSound()
    this.resizeObserver = new ResizeObserver(() => this.layout())
    this.resizeObserver.observe(this.canvasTarget)
    this.layout()
  }

  disconnect() {
    this.resizeObserver?.disconnect()
    cancelAnimationFrame(this.frame)
    this.closeAudio()
  }

  // ---- dropping -------------------------------------------------------------------------------------------------

  async drop() {
    if (this.busy || this.ballsValue < 1) return

    this.busy = true
    this.dropTarget.disabled = true
    this.landed = null
    this.ball = null
    this.draw()
    this.say("Dropping...")
    this.startAudio() // inside the click, so the browser lets it play

    // The same key is reused if the request has to be retried, so one click can never spend two balls.
    this.pendingKey ||= this.newKey()
    let result
    try {
      result = await this.post(this.pendingKey)
    } catch {
      this.say("Could not reach Battletown. Check your connection and press the button again.")
      return this.finish()
    }

    if (result.status === 429) {
      this.say("Slow down a little, then press the button again.")
      return this.finish()
    }
    this.pendingKey = null
    const body = result.body
    if (!result.ok) {
      if (body.error === "no_balls") this.setBalls(0)
      this.say(body.message || "That drop could not be made. Reload the page and try again.")
      return this.finish()
    }

    this.setBalls(body.balls.available)
    this.renderNext(body.balls.seconds_to_next)
    await this.play(body.path, body.slot)
    this.renderResult(body)
    this.finish()
  }

  finish() {
    this.busy = false
    this.dropTarget.disabled = this.ballsValue < 1
  }

  async post(key) {
    const token = document.querySelector("meta[name=csrf-token]")?.content
    const response = await fetch(this.urlValue, {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json", "Accept": "application/json", "X-CSRF-Token": token || "" },
      body: JSON.stringify({ idempotency_key: key })
    })
    let body = {}
    try {
      body = await response.json()
    } catch {
      // A non-JSON answer (a gateway error page): treated as a failed drop below.
    }
    return { ok: response.ok, status: response.status, body }
  }

  newKey() {
    if (crypto.randomUUID) return crypto.randomUUID()
    const bytes = crypto.getRandomValues(new Uint8Array(16))
    return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("")
  }

  setBalls(count) {
    this.ballsValue = count
    this.ballsTarget.textContent = String(count)
    this.ballsLabelTarget.textContent = count === 1 ? "ball" : "balls"
  }

  renderNext(secondsToNext) {
    const minutes = Math.max(Math.ceil(secondsToNext / 60), 1)
    this.nextTarget.textContent = `Next ball in about ${minutes} more ${minutes === 1 ? "minute" : "minutes"} of coding.`
  }

  renderResult(body) {
    this.todayTarget.textContent = this.number(body.totals.today)
    this.weekTarget.textContent = this.number(body.totals.week)
    this.totalTarget.textContent = this.number(body.totals.all_time)
    if (body.rank) {
      this.rankTarget.textContent = `Your place this week: #${body.rank.position} of ${body.rank.players} ${body.rank.players === 1 ? "player" : "players"}. Only you see this, whether or not you are on the leaderboard.`
    }
    const left = this.ballsValue === 0 ? "No balls left." : `${this.ballsValue} ${this.ballsValue === 1 ? "ball" : "balls"} left.`
    this.say(`Landed in slot ${body.slot + 1} of ${this.rowsValue + 1}: ${this.number(body.points)} points. ${left}`)
  }

  number(value) {
    return new Intl.NumberFormat().format(value)
  }

  say(text) {
    this.statusTarget.textContent = text
  }

  // ---- animation ------------------------------------------------------------------------------------------------

  play(path, slot) {
    const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches
    if (reduced) {
      this.landed = slot
      this.draw()
      this.chimeFor(slot)
      return Promise.resolve()
    }

    return new Promise((resolve) => {
      const levels = path.length
      const total = levels * STEP_MS + SETTLE_MS
      const start = performance.now()
      let rights = 0
      let lastRow = -1

      const step = (now) => {
        const elapsed = Math.min(now - start, total)
        const fallingRows = Math.min(elapsed / STEP_MS, levels)
        const row = Math.min(Math.floor(fallingRows), levels - 1)
        const t = fallingRows - row

        if (elapsed < levels * STEP_MS) {
          if (row !== lastRow) {
            if (row > 0) this.tick(row)
            lastRow = row
          }
          rights = path.slice(0, row).reduce((sum, bit) => sum + bit, 0)
          this.ball = this.between(row, rights, path[row], t)
        } else {
          if (lastRow !== levels) {
            this.tick(levels)
            lastRow = levels
          }
          const settle = (elapsed - levels * STEP_MS) / SETTLE_MS
          this.ball = this.intoSlot(slot, settle)
        }
        this.draw()

        if (elapsed < total) {
          this.frame = requestAnimationFrame(step)
        } else {
          this.ball = null
          this.landed = slot
          this.draw()
          this.chimeFor(slot)
          resolve()
        }
      }
      this.frame = requestAnimationFrame(step)
    })
  }

  // ---- geometry and drawing -------------------------------------------------------------------------------------

  layout() {
    const width = Math.max(Math.round(this.canvasTarget.clientWidth), 200)
    const height = Math.round(width * 1.08)
    const ratio = window.devicePixelRatio || 1
    this.canvasTarget.width = Math.round(width * ratio)
    this.canvasTarget.height = Math.round(height * ratio)
    this.canvasTarget.style.setProperty("block-size", `${height}px`)
    this.width = width
    this.height = height
    this.ratio = ratio

    const slots = this.rowsValue + 1
    this.pad = Math.max(width * 0.03, 8)
    this.dx = (width - this.pad * 2) / slots
    this.slotHeight = Math.min(Math.max(width * 0.11, 34), 56)
    this.top = this.dx * 0.7
    this.pegArea = height - this.slotHeight - this.top - 6
    this.dy = this.pegArea / this.rowsValue
    this.ballRadius = Math.max(Math.min(this.dx * 0.26, 11), 4)
    this.pegRadius = Math.max(this.ballRadius * 0.42, 2.5)
    this.draw()
  }

  // The x of a ball resting on peg number `rights` of row `row` (the pegs of row i are i + 1 wide, centred).
  pegX(row, rights) {
    return this.width / 2 + (rights - row / 2) * this.dx
  }

  pegY(row) {
    return this.top + row * this.dy
  }

  // From the top of the peg at (row, rights) to the one below it on the side the route takes.
  between(row, rights, bit, t) {
    const lift = this.ballRadius + this.pegRadius
    const x0 = this.pegX(row, rights)
    const x1 = this.pegX(row + 1, rights + bit)
    const y0 = this.pegY(row) - lift
    const y1 = this.pegY(row + 1) - lift
    const eased = t * t * (3 - 2 * t) // smooth sideways drift
    const hop = Math.sin(Math.PI * t) * this.dy * 0.3
    return { x: x0 + (x1 - x0) * eased, y: y0 + (y1 - y0) * t * t - hop }
  }

  intoSlot(slot, t) {
    const lift = this.ballRadius + this.pegRadius
    const rows = this.rowsValue
    const x = this.pegX(rows, slot)
    const from = this.pegY(rows) - lift
    const to = this.pegY(rows) + this.slotHeight * 0.55
    return { x, y: from + (to - from) * Math.min(t * t, 1) }
  }

  color(name) {
    return getComputedStyle(this.element).getPropertyValue(name).trim() || "#000"
  }

  draw() {
    const canvas = this.canvasTarget
    const context = canvas.getContext("2d")
    if (!context || !this.width) return

    context.setTransform(this.ratio, 0, 0, this.ratio, 0, 0)
    context.clearRect(0, 0, this.width, this.height)

    const rows = this.rowsValue
    const ink = this.color("--color-ink-blue")
    const cream = this.color("--color-bg")
    const text = this.color("--color-text")
    const yellow = this.color("--color-sign-yellow")
    const pink = this.color("--color-cta")

    // Slots along the bottom, with their points.
    const slotTop = this.pegY(rows)
    context.font = `${Math.max(Math.min(this.dx * 0.3, 14), 9)}px "M PLUS Rounded 1c", sans-serif`
    context.textAlign = "center"
    context.textBaseline = "middle"
    for (let slot = 0; slot <= rows; slot++) {
      const x = this.pegX(rows, slot) - this.dx / 2 + 1.5
      const width = this.dx - 3
      context.fillStyle = this.landed === slot ? yellow : cream
      context.strokeStyle = ink
      context.lineWidth = this.landed === slot ? 3 : 2
      context.beginPath()
      context.roundRect(x, slotTop, width, this.slotHeight, 6)
      context.fill()
      context.stroke()
      context.fillStyle = text
      context.fillText(String(this.pointsValue[slot]), x + width / 2, slotTop + this.slotHeight * 0.72)
    }

    // Pegs: row i has i + 1 of them.
    context.fillStyle = ink
    for (let row = 0; row < rows; row++) {
      for (let peg = 0; peg <= row; peg++) {
        context.beginPath()
        context.arc(this.pegX(row, peg), this.pegY(row), this.pegRadius, 0, Math.PI * 2)
        context.fill()
      }
    }

    const ball = this.ball || (this.landed !== null ? this.intoSlot(this.landed, 0.55) : null)
    if (ball) {
      context.beginPath()
      context.arc(ball.x, ball.y, this.ballRadius, 0, Math.PI * 2)
      context.fillStyle = pink
      context.fill()
      context.lineWidth = 2
      context.strokeStyle = text
      context.stroke()
    }
  }

  // ---- sound ----------------------------------------------------------------------------------------------------

  toggleSound() {
    this.muted = !this.muted
    try {
      localStorage.setItem(SOUND_KEY, this.muted ? "off" : "on")
    } catch {
      // Private mode or blocked storage: the choice just is not remembered.
    }
    this.renderSound()
    if (this.muted && this.master) this.master.gain.setTargetAtTime(0, this.audio.currentTime, 0.02)
    else if (!this.muted && this.master) this.master.gain.setTargetAtTime(MASTER_GAIN, this.audio.currentTime, 0.02)
  }

  renderSound() {
    this.soundTarget.setAttribute("aria-pressed", String(!this.muted))
    this.soundTarget.querySelector("[data-state]").textContent = this.muted ? "off" : "on"
  }

  storedMuted() {
    try {
      return localStorage.getItem(SOUND_KEY) === "off"
    } catch {
      return false
    }
  }

  // Only ever called from the click on the drop button.
  startAudio() {
    if (this.muted || this.audio) return

    try {
      this.audio = new (window.AudioContext || window.webkitAudioContext)()
      this.master = this.audio.createGain()
      this.master.gain.value = MASTER_GAIN
      this.master.connect(this.audio.destination)
      this.audio.resume().catch(() => {})
    } catch {
      this.audio = this.master = null
    }
  }

  closeAudio() {
    const { audio, master } = this
    this.audio = this.master = null
    if (!audio) return

    try {
      master?.gain.setTargetAtTime(0, audio.currentTime, 0.02)
      setTimeout(() => audio.close().catch(() => {}), 150)
    } catch {
      // Already closed.
    }
  }

  // A short wooden tick whose pitch climbs a little as the ball falls.
  tick(row) {
    this.note(380 + row * 45, 0.05, 0.5, "triangle")
  }

  // A soft bell: one note for an ordinary slot, a rising pair for the slots that pay the most.
  chimeFor(slot) {
    if (!this.audio || this.muted) return

    const best = Math.max(...this.pointsValue)
    const rare = this.pointsValue[slot] >= best / 2.5
    const base = 520 + (this.pointsValue[slot] / best) * 260
    this.note(base, 0.5, 0.7, "triangle")
    if (rare) {
      this.note(base * 1.25, 0.5, 0.6, "triangle", 0.12)
      this.note(base * 1.5, 0.7, 0.6, "triangle", 0.24)
    }
  }

  note(frequency, length, peak, type, delay = 0) {
    if (!this.audio || !this.master || this.muted || this.audio.state !== "running") return

    try {
      const start = this.audio.currentTime + delay
      const oscillator = this.audio.createOscillator()
      oscillator.type = type
      oscillator.frequency.value = frequency
      const gain = this.audio.createGain()
      gain.gain.setValueAtTime(SILENT, start)
      gain.gain.linearRampToValueAtTime(peak, start + 0.008)
      gain.gain.exponentialRampToValueAtTime(SILENT, start + length)
      oscillator.connect(gain).connect(this.master)
      oscillator.start(start)
      oscillator.stop(start + length + 0.05)
    } catch {
      // Audio is a bonus: never let it break the page.
    }
  }
}
