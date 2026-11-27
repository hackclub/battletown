import { Controller } from "@hotwired/stimulus"
import { whoamiWithin } from "controllers/whoami_client"

// A landing-page sign-up button for a visitor Hack Club Auth already knows: once it says they are signed in (within `within` ms, else nothing
// changes), the label reads as logging in and the button sends the existing Hack Club sign-in request (the page's hidden form, with its CSRF
// token) instead of opening onboarding. Who they are is decided only by that real sign-in, never by this answer. Without an answer the button
// is the plain link it always was.
export default class extends Controller {
  static values = { url: String, label: String, form: String, within: { type: Number, default: 1500 } }

  async connect() {
    this.swapped = false
    const answer = await whoamiWithin(this.urlValue, this.withinValue)
    if (!answer || !answer.signedIn || !this.element.isConnected) return
    const label = this.element.querySelector(".cta__label")
    if (!label || !this.labelValue) return
    // Keep the button at least as wide as it was, so a shorter label never pulls its edges in.
    const before = this.element.getBoundingClientRect().width
    label.textContent = this.labelValue
    this.element.style.minWidth = `${Math.ceil(before)}px`
    this.element.dataset.turbo = "false"
    this.element.setAttribute("role", "button")
    this.element.dataset.whoamiState = "login"
    this.swapped = true
  }

  go(event) {
    if (!this.swapped || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
    const form = document.getElementById(this.formValue)
    if (!form) return
    event.preventDefault()
    form.requestSubmit()
  }
}
