import { Controller } from "@hotwired/stimulus"

// The dashboard's to-do list. It keeps exactly one empty line at the end: fill in the last line and a new empty one appears under
// it (copied from the template), up to the limit; clear a line and the extra empty ones go. It also saves itself: a short pause
// after typing, or at once when a line is ticked or left, the form is sent in the background. Without JavaScript the Save button
// submits the form as usual (it is hidden once this runs) and the page it comes back to has the next empty line. A failed save
// says so in the status line and keeps what was typed.
export default class extends Controller {
  static targets = ["form", "lines", "line", "template", "save", "status"]
  static values = { limit: Number }

  connect() {
    if (this.hasSaveTarget) this.saveTarget.hidden = true
    this.timer = null
    this.sending = false
    this.again = false
    this.counter = this.lineTargets.length
  }

  disconnect() {
    clearTimeout(this.timer)
  }

  // Each keystroke: keep one empty line at the end, and save after a pause.
  typed() {
    this.tidy()
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.save(), 700)
  }

  async save() {
    clearTimeout(this.timer)
    this.tidy()
    if (this.sending) { this.again = true; return }

    this.sending = true
    this.say("Saving…")
    try {
      const response = await fetch(this.formTarget.action, {
        method: "POST",
        body: new FormData(this.formTarget),
        headers: { Accept: "application/json" },
        credentials: "same-origin"
      })
      this.say(response.ok ? "Saved" : "Couldn't save. Try again.")
    } catch (error) {
      this.say("Couldn't save. Check your connection.")
    } finally {
      this.sending = false
      if (this.again) { this.again = false; this.save() }
    }
  }

  // Exactly one empty line at the end: add one when there is none (room permitting), and drop the surplus empty ones, never the
  // one being typed in.
  tidy() {
    const empty = this.lineTargets.filter((line) => this.bodyOf(line).value.trim() === "")
    if (empty.length === 0) {
      if (this.lineTargets.length < this.limitValue) this.addLine()
      return
    }

    const keep = empty[empty.length - 1]
    empty.filter((line) => line !== keep && !this.focused(line)).forEach((line) => line.remove())
  }

  addLine() {
    this.counter += 1
    const html = this.templateTarget.innerHTML.replaceAll("__SLOT__", String(this.counter))
    this.linesTarget.insertAdjacentHTML("beforeend", html)
  }

  bodyOf(line) {
    return line.querySelector("input[type='text']")
  }

  focused(line) {
    return line.contains(document.activeElement)
  }

  say(message) {
    if (this.hasStatusTarget) this.statusTarget.textContent = message
  }
}
