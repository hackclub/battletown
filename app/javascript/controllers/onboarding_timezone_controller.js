import { Controller } from "@hotwired/stimulus"

// Preselects the browser's time zone when none is saved. The server still validates whatever is submitted.
export default class extends Controller {
  static targets = ["select"]

  connect() {
    if (this.selectTarget.value) return

    const iana = Intl.DateTimeFormat().resolvedOptions().timeZone
    const match = Array.from(this.selectTarget.options).find((option) => option.dataset.iana === iana)
    if (match) this.selectTarget.value = match.value
  }
}
