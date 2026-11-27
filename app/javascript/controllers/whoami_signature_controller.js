import { Controller } from "@hotwired/stimulus"
import { whoami } from "controllers/whoami_client"

// The pledge's signature line: when Hack Club Auth already knows the visitor, their first name is written on it as the hold fills (listening
// to the hold's "pledge-hold:progress" event), and rewinds when the hold does. With reduced motion there is no hold, so it is simply there.
// Text only (textContent). No name known, or no answer: the line stays empty, as before.
export default class extends Controller {
  static values = { url: String }

  async connect() {
    this.progress_ = 0
    this.reduced = matchMedia("(prefers-reduced-motion: reduce)").matches
    const answer = await whoami(this.urlValue)
    if (!answer.signedIn || !answer.firstName || !this.element.isConnected) return
    this.mark = document.createElement("span")
    this.mark.className = "pledge__signed-name"
    this.mark.textContent = answer.firstName
    this.element.append(this.mark)
    this.show(this.reduced ? 1 : this.progress_)
  }

  disconnect() { this.mark?.remove() }

  progress(event) {
    this.progress_ = event.detail?.p || 0
    if (this.mark && !this.reduced) this.show(this.progress_)
  }

  show(p) {
    const left = Math.max(0, Math.min(1, p))
    this.mark.style.clipPath = `inset(0 ${((1 - left) * 100).toFixed(1)}% 0 0)`
  }
}
