import { Controller } from "@hotwired/stimulus"

// Moves focus on each step so keyboard and screen reader users land in the right place: the error summary when the
// form came back with errors (it is announced and its links jump to the fields), the step heading otherwise.
export default class extends Controller {
  static targets = ["heading", "errors"]

  connect() {
    const target = this.hasErrorsTarget ? this.errorsTarget : this.headingTarget
    target.focus({ preventScroll: !this.hasErrorsTarget })
  }
}
