import { Controller } from "@hotwired/stimulus"

// Moves focus on each step so keyboard and screen reader users land in the right place: the error summary when the
// form came back with errors (it is announced and its links jump to the fields), the step heading otherwise.
//
// It also gives the step its motion (all of it off under prefers-reduced-motion): a step change is one move, a cross-fade of 200ms. The new step fades
// in by CSS (onboarding_world.css); here the leaving step is copied (the ghost) and laid over the new one, where it fades out in the same time.
// Nothing waits for the ghost, so Turbo renders at once and Continue and the auto-advance never wait. A single-choice radio that answers on its own (the pace) shows its pick for a beat before it sends,
// once only, so a second tap during the beat does nothing. What a pick looks like is never set here: CSS reads the input's :checked state.
const BEAT = 200
const MOVE = 200
const reduced = () => matchMedia("(prefers-reduced-motion: reduce)").matches
let previewed = false // the last render of this visit was a cached preview, so the real render that follows must not play the entrance again
let pending = null // the ghost made just before a render, laid on the page right after it
document.addEventListener("turbo:visit", () => { previewed = false; pending = null })
// The ghost goes in after the swap, not into the incoming body: that body belongs to a parsed copy of the page, and an animation started there never runs.
document.addEventListener("turbo:render", () => {
  if (!pending) return
  const { host, ghost, to } = pending
  pending = null
  document.body.append(host)
  const fade = ghost.animate([ { opacity: 1, translate: "0 0" }, { opacity: 0, translate: to } ], { duration: MOVE, easing: "ease", fill: "forwards" })
  const remove = () => host.remove()
  fade.addEventListener("finish", remove)
  setTimeout(remove, MOVE + 150)
})

export default class extends Controller {
  static targets = ["heading", "errors"]

  connect() {
    const target = this.hasErrorsTarget ? this.errorsTarget : this.headingTarget
    target.focus({ preventScroll: !this.hasErrorsTarget })
    this.onBeforeCache = () => this.syncChecked()
    this.onBeforeRender = (event) => this.cross(event)
    this.onVisit = (event) => { this.restoring = event.detail.action === "restore" }
    document.addEventListener("turbo:before-render", this.onBeforeRender)
    document.addEventListener("turbo:visit", this.onVisit)
    this.onPageshow = (event) => { if (event.persisted) this.reveal() }
    window.addEventListener("pageshow", this.onPageshow)
    document.addEventListener("turbo:before-cache", this.onBeforeCache)
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
    if (!form || form.dataset.sending || !input.checked) return
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

  // Turbo is about to swap in the next step: copy the one on screen and lay the copy over the new one, then fade it out while the new one fades in.
  cross(event) {
    const preview = document.documentElement.hasAttribute("data-turbo-preview")
    const wasPreview = previewed
    previewed = preview
    document.documentElement.dataset.obDir = this.restoring ? "back" : ""
    const page = event.detail.newBody.querySelector(".onboarding-page")
    const here = this.element.querySelector(".onboarding")
    if (!page || !here || reduced() || !here.animate || event.detail.newBody.querySelector(".transition")) return
    if (wasPreview && !preview) return page.querySelector(".onboarding__panel")?.classList.add("is-settled")

    const box = here.getBoundingClientRect()
    const ghost = here.cloneNode(true)
    // a copy: no controllers, no ids, nothing to focus or announce; the inputs show what the person picked
    ghost.querySelectorAll("*").forEach((el) => { for (const name of el.getAttributeNames()) if (name.startsWith("data-") || name === "id" || name === "name" || name === "for") el.removeAttribute(name) })
    const live = [...here.querySelectorAll("input, select, textarea")]
    ghost.querySelectorAll("input, select, textarea").forEach((copy, i) => {
      const input = live[i]
      if (input.type === "radio" || input.type === "checkbox") copy.toggleAttribute("checked", input.checked)
      else if (copy.tagName === "SELECT") [...copy.options].forEach((option, j) => option.toggleAttribute("selected", input.options[j].selected))
      else copy.setAttribute("value", input.value)
    })
    ghost.classList.add("ob-ghost")
    ghost.setAttribute("aria-hidden", "true")
    ghost.setAttribute("inert", "")
    ghost.setAttribute("data-turbo-temporary", "")
    Object.assign(ghost.style, { left: `${box.left}px`, top: `${box.top}px`, width: `${box.width}px`, height: `${box.height}px` })
    // laid outside the new page: inside it, the copy's cards would change what the new page's own rules (:has) measure
    const host = this.element.cloneNode(false)
    for (const name of host.getAttributeNames()) if (name.startsWith("data-")) host.removeAttribute(name)
    host.classList.add("ob-ghost-host")
    host.setAttribute("aria-hidden", "true")
    host.setAttribute("data-turbo-temporary", "")
    host.append(ghost)
    pending = { host, ghost, to: this.restoring ? "0 6px" : "0 -6px" }
  }

  // A page back from the browser's cache comes back as it was left: drop any animation still on it, so nothing is stuck half-faded.
  reveal() { document.getAnimations().forEach((animation) => animation.cancel()) }
}
