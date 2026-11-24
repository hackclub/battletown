import { Controller } from "@hotwired/stimulus"

// Submits its form as soon as the page loads (the page between Hack Club sign-in and Hackatime). The button stays for when
// scripts do not run, and for someone who comes back to the page with the Back button: it only fires once per page load.
export default class extends Controller {
  connect() {
    if (this.element.dataset.submitted) return

    this.element.dataset.submitted = "true"
    this.element.requestSubmit()
  }
}
