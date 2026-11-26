import { Controller } from "@hotwired/stimulus"

// Progressive enhancement for the schedule step's time zone. The server already preselects the zone it derived
// from the address; the select inside the <details> submits with the form either way.
//   * No zone saved or derived: preselect the browser's zone (client-side only, never sent anywhere except as the
//     normal form value) and fold the <details> back up (the server opens it for people without JavaScript), so the
//     step stays one screen; the summary line still offers the change. If no zone matches, it stays open.
//   * The user changes the zone: keep the "We'll use ..." line in sync.
// The server still validates whatever is submitted.
export default class extends Controller {
  static targets = ["select", "details", "name"]

  connect() {
    if (this.selectTarget.value) return

    const iana = Intl.DateTimeFormat().resolvedOptions().timeZone
    const match = Array.from(this.selectTarget.options).find((option) => option.dataset.iana === iana)
    if (!match) return

    this.selectTarget.value = match.value
    this.update()
    this.detailsTarget.open = false
  }

  update() {
    if (!this.hasNameTarget) return

    const option = this.selectTarget.selectedOptions[0]
    if (option && option.value) this.nameTarget.textContent = option.value
  }
}
