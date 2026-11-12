import { Controller } from "@hotwired/stimulus"

// Copies the text of the "source" input to the clipboard. Progressive enhancement: the Copy button is hidden until this
// controller connects, and the input stays selectable by hand without JavaScript.
export default class extends Controller {
  static targets = ["source", "button", "status"]

  connect() {
    if (this.hasButtonTarget && navigator.clipboard) this.buttonTarget.hidden = false
  }

  async copy() {
    try {
      await navigator.clipboard.writeText(this.sourceTarget.value)
      this.say("Copied.")
    } catch {
      this.sourceTarget.select()
      this.say("Press Ctrl+C or Cmd+C to copy.")
    }
  }

  say(text) {
    if (this.hasStatusTarget) this.statusTarget.textContent = text
  }
}
