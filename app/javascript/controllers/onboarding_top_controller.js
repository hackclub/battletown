import { Controller } from "@hotwired/stimulus"

// The strip at the top of onboarding (the progress bar, and the label and count that only screen readers get) is data-turbo-permanent, so
// Turbo keeps this element across steps instead of redrawing it. Just before it swaps in the next step, copy what the
// server rendered for that step into the kept strip: the bar's value changes in place (and slides), the rest is text.
// The server stays the source of truth for the step and its numbers; nothing is worked out here.
export default class extends Controller {
  // Turbo is about to swap in the next step: remember its strip (the kept one is what stays on the page).
  prepare(event) {
    this.next = event.detail.newBody.querySelector("#onboarding-top")?.cloneNode(true)
  }

  // The step is in: bring the kept strip up to date. Done after the swap, not before, so that the snapshot Turbo caches of
  // the step we just left still holds that step's own numbers (it is cloned a moment after the visit starts).
  update() {
    const next = this.next
    this.next = null
    if (!next) return

    for (const selector of [".onboarding-top__label", ".onboarding-top__step"]) {
      const here = this.element.querySelector(selector)
      const there = next.querySelector(selector)
      if (here && there) here.textContent = there.textContent
    }

    const bar = this.element.querySelector("progress")
    const nextBar = next.querySelector("progress")
    if (bar && nextBar) {
      bar.max = nextBar.max
      bar.value = nextBar.value
      bar.textContent = nextBar.textContent
    }

    // Turbo hands focus back to a kept element that had it (the logo link). The new step's own focus
    // rule (its heading, or its error summary) must win, as it does after a full page load.
    if (this.element.contains(document.activeElement)) {
      const target = document.querySelector("[data-onboarding-step-target='errors']") || document.querySelector("[data-onboarding-step-target='heading']")
      target?.focus({ preventScroll: true })
    }
  }
}
