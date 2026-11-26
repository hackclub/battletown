import { Controller } from "@hotwired/stimulus"

// Keeps a step's Continue button looking and acting unavailable until a required choice is made (a radio picked, or
// at least one day ticked). The inputs stay the source of truth the form submits and the server still validates, so
// without JavaScript Continue simply works and the error box is the fallback.
// The button uses aria-disabled rather than the disabled attribute, so keyboard and screen reader users can still
// reach it and hear it is unavailable, with the step's own sentence ("Choose what you're working toward.") as its
// description (aria-describedby is set in the markup). Pressing it does nothing until a choice is made.
export default class extends Controller {
  static targets = ["input", "submit"]

  connect() {
    this.sync()
  }

  sync() {
    this.submitTarget.setAttribute("aria-disabled", String(!this.ready))
  }

  guard(event) {
    if (!this.ready) event.preventDefault()
  }

  get ready() {
    return this.inputTargets.some((input) => input.checked)
  }
}
