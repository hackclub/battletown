import { Controller } from "@hotwired/stimulus"

// Shows a Basecoat toast: copies the <template> target into the toaster list (an <ol class="toaster">); Basecoat's own
// script (the pinned "basecoat" module) notices the new <li class="toast"> and runs its timer, swipe and close. No inline
// handlers, so it works under the site's script-src 'self' policy.
export default class extends Controller {
  static targets = ["toaster", "template"]

  show() {
    this.toasterTarget.append(this.templateTarget.content.cloneNode(true))
  }
}
