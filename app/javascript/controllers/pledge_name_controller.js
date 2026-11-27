import { Controller } from "@hotwired/stimulus"

// The signed name is written letter by letter (a stepped animation); the step count is the name's length. A style attribute in the HTML is blocked
// by the CSP, so the custom property is set here, where the CSP allows it.
export default class extends Controller {
  connect() {
    this.element.style.setProperty("--chars", String(Math.max(1, this.element.textContent.trim().length)))
  }
}
