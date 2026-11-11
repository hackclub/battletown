import { Controller } from "@hotwired/stimulus"

// Moves focus to the step heading on each step so keyboard and screen reader users land in the right place.
export default class extends Controller {
  static targets = ["heading"]

  connect() {
    this.headingTarget.focus({ preventScroll: true })
  }
}
