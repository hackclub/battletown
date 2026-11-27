import { Controller } from "@hotwired/stimulus"

// The picked prize's picture, docked at the top left. Turbo keeps this element across steps (data-turbo-permanent). When the dock first
// appears or the pick changes and a flight was recorded for that prize, the picture flies from the card along a curve and stays.
// After a reload, or coming back later, nothing was recorded, so it is simply there. Reduced motion: no flight.
export default class extends Controller {
  static targets = ["image"]

  // Turbo moves this element to the new step on every visit, and a move runs connect again: only its first appearance counts.
  connect() {
    const first = !this.element.dataset.shown
    this.element.dataset.shown = "true"
    const flies = this.flyIfRecorded()
    if (first && !flies && !matchMedia("(prefers-reduced-motion: reduce)").matches) this.element.animate([ { opacity: 0 }, { opacity: 1 } ], { duration: 200, easing: "ease" })
  }

  prepare(event) { this.next = event.detail.newBody.querySelector("#onboarding-prize-dock")?.cloneNode(true) }

  update() {
    const next = this.next
    this.next = null
    if (next) this.element.classList.toggle("onboarding-dock--away", next.classList.contains("onboarding-dock--away"))
    if (!next || next.dataset.prizeKey === this.element.dataset.prizeKey) return
    this.element.dataset.prizeKey = next.dataset.prizeKey
    this.element.title = next.title
    const there = next.querySelector("img")
    this.imageTarget.src = there.getAttribute("src")
    this.imageTarget.alt = there.alt
    this.flyIfRecorded()
  }

  flyIfRecorded() {
    const raw = sessionStorage.getItem("battletown-prize-flight")
    if (!raw) return false
    sessionStorage.removeItem("battletown-prize-flight")
    const from = JSON.parse(raw)
    if (from.key !== this.element.dataset.prizeKey) return false
    if (matchMedia("(prefers-reduced-motion: reduce)").matches || !this.element.animate) return false

    const to = this.element.getBoundingClientRect()
    const p0 = { x: from.x + from.w / 2 - to.x - to.width / 2, y: from.y + from.h / 2 - to.y - to.height / 2 }
    const p1 = { x: p0.x, y: 0 } // the control point: leave the card going straight across, then swing up into the corner (an arc, not a line)
    const s0 = from.w / to.width
    const ease = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2)
    const frames = []
    for (let i = 0; i <= 24; i++) {
      const t = ease(i / 24)
      const a = (1 - t) * (1 - t), b = 2 * (1 - t) * t, c = t * t
      const x = a * p0.x + b * p1.x
      const y = a * p0.y + b * p1.y
      frames.push({ transform: `translate(${x}px, ${y}px) scale(${s0 + (1 - s0) * t})` })
    }
    this.element.animate(frames, { duration: 650, easing: "linear" })
    return true
  }
}
