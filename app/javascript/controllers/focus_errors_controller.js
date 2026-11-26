import { Controller } from "@hotwired/stimulus"

// A page that came back with a form error (a plain re-render, no new page): move focus to the error summary and scroll it into view,
// so a keyboard or screen reader user, or someone on a phone looking at the top of a long page, knows the save failed. The element
// needs tabindex="-1". Does nothing when there is no error inside.
export default class extends Controller {
  connect() {
    if (!this.element.querySelector("[role='alert']")) return
    this.element.focus()
    this.element.scrollIntoView({ block: "center" })
  }
}
