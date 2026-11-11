import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["field", "count"]

  connect() {
    this.count()
  }

  fill({ params: { text } }) {
    this.fieldTarget.value = text
    this.count()
    this.fieldTarget.focus()
  }

  count() {
    this.countTarget.textContent = this.fieldTarget.value.length
  }
}
