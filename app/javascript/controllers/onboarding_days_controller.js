import { Controller } from "@hotwired/stimulus"

// "Every day" toggle for the day pills. The checkboxes stay the source of truth that the form submits; this only
// ticks or clears them and keeps aria-pressed in sync. The button is rendered hidden and revealed here, so
// without JavaScript the pills still work on their own.
export default class extends Controller {
  static targets = ["day", "all"]

  connect() {
    this.allTarget.hidden = false
    this.sync()
  }

  toggleAll() {
    const check = !this.everyDay
    this.dayTargets.forEach((day) => { day.checked = check })
    this.sync()
  }

  sync() {
    this.allTarget.setAttribute("aria-pressed", String(this.everyDay))
  }

  get everyDay() {
    return this.dayTargets.length > 0 && this.dayTargets.every((day) => day.checked)
  }
}
