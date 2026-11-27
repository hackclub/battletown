import { Controller } from "@hotwired/stimulus"

// Moves focus on each step so keyboard and screen reader users land in the right place: the error summary when the
// form came back with errors (it is announced and its links jump to the fields), the step heading otherwise.
//
// It also gives the step its motion (all of it off under prefers-reduced-motion): the question leaves with a short fade and slide before Turbo
// swaps the next one in (which fades in by CSS), and a single-choice radio that answers on its own (the pace) shows its pick for a beat before it sends,
// once only, so a second tap during the beat does nothing. What a pick looks like is never set here: CSS reads the input's :checked state.
const BEAT = 200
const LEAVE = 160
const reduced = () => matchMedia("(prefers-reduced-motion: reduce)").matches

export default class extends Controller {
  static targets = ["heading", "errors"]

  connect() {
    const target = this.hasErrorsTarget ? this.errorsTarget : this.headingTarget
    target.focus({ preventScroll: !this.hasErrorsTarget })
    this.onBeforeCache = () => this.syncChecked()
    this.onBeforeRender = (event) => this.leave(event)
    this.onVisit = (event) => this.visit(event)
    this.onPageshow = (event) => { if (event.persisted) this.reveal() }
    document.addEventListener("turbo:visit", this.onVisit)
    window.addEventListener("pageshow", this.onPageshow)
    document.addEventListener("turbo:before-cache", this.onBeforeCache)
    document.addEventListener("turbo:before-render", this.onBeforeRender)
  }

  disconnect() {
    document.removeEventListener("turbo:before-cache", this.onBeforeCache)
    document.removeEventListener("turbo:before-render", this.onBeforeRender)
    document.removeEventListener("turbo:visit", this.onVisit)
    window.removeEventListener("pageshow", this.onPageshow)
  }

  // A radio that answers on its own: the pick shows at once (CSS :checked), the form goes a beat later.
  choose(event) {
    const input = event.target
    const form = input.form
    if (!form || form.dataset.sending) return
    form.dataset.sending = "true"
    if (reduced()) return form.requestSubmit()
    setTimeout(() => form.requestSubmit(), BEAT)
  }

  // Turbo caches a copy of the page by cloning it, and a clone keeps the checked attribute, not what the person last picked: write the live
  // state into the attributes first, so a snapshot (and Back) shows exactly the inputs' state.
  syncChecked() {
    this.element.querySelectorAll("input[type=radio], input[type=checkbox]").forEach((input) => input.toggleAttribute("checked", input.checked))
    this.element.querySelectorAll("form[data-sending]").forEach((form) => delete form.dataset.sending)
  }

  // The slide-out never decides whether the next step shows: a back or forward visit, a cached preview, and anything unusual skip it, and the
  // render always resumes on a timer (not on the animation's promise, which a cancelled animation would never settle).
  leave(event) {
    const panel = this.element.querySelector(".onboarding__panel")
    const preview = document.documentElement.hasAttribute("data-turbo-preview")
    document.documentElement.dataset.obDir = this.restoring ? "back" : ""
    if (!panel || reduced() || !panel.animate || preview || this.restoring || event.detail.newBody.querySelector(".transition")) return
    event.preventDefault()
    const slide = panel.animate([ { opacity: 1, translate: "0 0" }, { opacity: 0, translate: "0 -8px" } ], { duration: LEAVE, easing: "ease-in" })
    setTimeout(() => { slide.cancel(); event.detail.resume() }, LEAVE)
  }

  visit(event) { this.restoring = event.detail.action === "restore" }

  // A page back from the browser's cache comes back as it was left: drop any animation still on it, so nothing is stuck half-faded.
  reveal() { document.getAnimations().forEach((animation) => animation.cancel()) }
}
