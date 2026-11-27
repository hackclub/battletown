import { Controller } from "@hotwired/stimulus"

// Hold to sign: pressing fills the button left to right, and a full fill signs the pledge, which is signing in with Hack Club (the form goes to the
// existing sign-up request). Letting go early runs the fill back. A quick tap (as if it were an ordinary button) runs a quarter of the way to show
// what holding does; a second quick tap means holding is not working for this person, so it fills and signs by itself. Space and Enter can be held.
// With reduced motion, or without JavaScript, a plain press signs at once.
const HOLD = { fill: 1300, rewind: 350, tap: 260, demo: 0.25, taps: 2 }
const reduced = () => matchMedia("(prefers-reduced-motion: reduce)").matches
const HINTS = {
  rest: "Press and hold to sign.", holding: "Keep holding.", early: "Hold a little longer.",
  tapped: "Hold it down until it fills.", auto: "Signing for you.", signing: "Signing in with Hack Club."
}

export default class extends Controller {
  static targets = ["button", "form", "hint"]

  connect() {
    this.p = 0
    this.taps = 0
    this.holding = false
    this.signing = false
    this.auto = false
    this.onPageshow = (event) => { if (event.persisted) this.reset() }
    window.addEventListener("pageshow", this.onPageshow)
    this.paint()
  }

  disconnect() {
    cancelAnimationFrame(this.raf)
    window.removeEventListener("pageshow", this.onPageshow)
  }

  start(event) {
    if (reduced() || this.signing || this.holding || this.auto) return
    if (event.pointerId != null) {
      if (event.button !== 0) return
      try { event.currentTarget.setPointerCapture(event.pointerId) } catch {}
    }
    this.holding = true
    this.since = performance.now()
    this.say("holding")
    this.animate(1, HOLD.fill * (1 - this.p), () => this.sign())
  }

  end() {
    if (!this.holding || this.auto) return
    this.holding = false
    const tapped = performance.now() - this.since < HOLD.tap
    if (tapped) this.taps += 1
    if (tapped && this.taps >= HOLD.taps) {
      this.auto = true
      this.say("auto")
      return this.animate(1, HOLD.fill * (1 - this.p), () => this.sign())
    }
    if (tapped && this.p < HOLD.demo) {
      this.say("tapped")
      return this.animate(HOLD.demo, 200, () => this.animate(0, HOLD.rewind * HOLD.demo))
    }
    this.say(tapped ? "tapped" : "early")
    this.animate(0, HOLD.rewind * this.p)
  }

  key(event) {
    if (event.key !== " " && event.key !== "Enter") return
    if (reduced()) return
    event.preventDefault()
    if (!event.repeat) this.start(event)
  }

  keyEnd(event) {
    if (event.key === " " || event.key === "Enter") this.end()
  }

  // A click is not a hold, so it signs nothing: only with reduced motion does a plain press go straight through.
  click(event) {
    if (reduced()) { this.say("signing"); return }
    event.preventDefault()
  }

  sign() {
    this.signing = true
    this.holding = false
    this.say("signing")
    this.formTarget.submit()
  }

  reset() {
    cancelAnimationFrame(this.raf)
    this.p = 0
    this.signing = this.holding = this.auto = false
    this.taps = 0
    this.say("rest")
    this.paint()
  }

  animate(to, duration, done) {
    cancelAnimationFrame(this.raf)
    const from = this.p
    const t0 = performance.now()
    const step = (now) => {
      const k = duration <= 0 ? 1 : Math.min(1, (now - t0) / duration)
      this.p = from + (to - from) * k
      this.paint()
      if (k < 1) this.raf = requestAnimationFrame(step)
      else done?.()
    }
    this.raf = requestAnimationFrame(step)
  }

  paint() {
    this.buttonTarget.style.setProperty("--hold", this.p.toFixed(3))
    this.dispatch("progress", { detail: { p: this.p } }) // the signature line listens (whoami_signature_controller.js)
  }
  say(key) { if (this.hasHintTarget) this.hintTarget.textContent = HINTS[key] }
}
