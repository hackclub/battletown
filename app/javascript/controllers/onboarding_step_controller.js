import { Controller } from "@hotwired/stimulus"

// Moves focus on each step so keyboard and screen reader users land in the right place: the error summary when the
// form came back with errors (it is announced and its links jump to the fields), the step heading otherwise.
//
// It also gives the step its motion (all of it off under prefers-reduced-motion): the question leaves with a short fade and slide before Turbo
// swaps the next one in (which fades in by CSS), and a single-choice card (the age answer, the pace) shows its pick for a beat before it sends,
// once only, so a second tap during the beat does nothing.
const BEAT = 200
const LEAVE = 160
const reduced = () => matchMedia("(prefers-reduced-motion: reduce)").matches

export default class extends Controller {
  static targets = ["heading", "errors"]

  connect() {
    const target = this.hasErrorsTarget ? this.errorsTarget : this.headingTarget
    target.focus({ preventScroll: !this.hasErrorsTarget })
    this.onClick = (event) => this.beat(event)
    this.onBeforeRender = (event) => this.leave(event)
    this.element.addEventListener("click", this.onClick)
    document.addEventListener("turbo:before-render", this.onBeforeRender)
  }

  disconnect() {
    this.element.removeEventListener("click", this.onClick)
    document.removeEventListener("turbo:before-render", this.onBeforeRender)
  }

  beat(event) {
    const button = event.target.closest("button.age-choice")
    if (!button || reduced() || button.form?.dataset.sending) return
    event.preventDefault()
    const form = button.form
    form.dataset.sending = "true"
    button.classList.add("is-picked")
    setTimeout(() => form.requestSubmit(button), BEAT)
  }

  leave(event) {
    const panel = this.element.querySelector(".onboarding__panel")
    if (!panel || reduced() || !panel.animate || event.detail.newBody.querySelector(".transition")) return
    event.preventDefault()
    panel.animate([{ opacity: 1, translate: "0 0" }, { opacity: 0, translate: "0 -8px" }], { duration: LEAVE, easing: "ease-in", fill: "forwards" }).finished
      .then(() => event.detail.resume())
  }
}
