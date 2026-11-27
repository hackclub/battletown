import { Controller } from "@hotwired/stimulus"

// The pace step's slider (views/onboardings/_pace_slider). The range input only picks a stop; the hidden field carries the minutes the form posts, so the
// controller and Onboarding::Flow see the same param as before. Each stop's words and finish date are rendered by the server (data attributes), so the
// readout uses the same arithmetic as the pace-date screen. The slider is hidden until this connects: without JavaScript the hidden field's default is sent.
export default class extends Controller {
  static targets = ["field", "body", "input", "readout", "pace", "finish", "stop", "track"]

  connect() {
    this.bodyTarget.hidden = false
    this.sync(false) // a restored form (Back) may hold another stop than the server rendered: the range is the truth
  }

  change() { this.sync(true) }

  sync(animate) {
    const index = Number(this.inputTarget.value)
    const stop = this.stopTargets[index]
    if (!stop) return
    this.fieldTarget.value = stop.dataset.minutes
    const last = Math.max(this.stopTargets.length - 1, 1)
    this.trackTarget.style.setProperty("--pos", index / last) // CSSOM, not a style attribute: the content security policy allows it
    this.inputTarget.setAttribute("aria-valuetext", stop.dataset.pace)
    if (this.paceTarget.textContent === stop.dataset.pace) return
    this.paceTarget.textContent = stop.dataset.pace
    this.finishTarget.textContent = stop.dataset.finish
    if (animate) this.swap()
  }

  // A short fade of the readout, restarted on each change (none under reduced motion: the stylesheet only animates there when motion is allowed).
  swap() {
    this.readoutTarget.classList.remove("slider__readout--swap")
    void this.readoutTarget.offsetWidth
    this.readoutTarget.classList.add("slider__readout--swap")
  }
}
