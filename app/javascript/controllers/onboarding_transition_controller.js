import { Controller } from "@hotwired/stimulus"

// A transition screen (the welcome splash, or "others like you" after the prize and project steps) plays over the step
// and fades itself out with CSS, so nobody has to click anything. This lets people skip it early (a click, or a key press).
// A key press never has its default action cancelled, so Tab, Enter, Space and the arrow keys keep working: pressing Tab
// skips the overlay and moves focus on as normal (focus would otherwise land on something hidden under it). Lone modifier
// keys and browser shortcuts (Ctrl, Cmd or Alt held, like Ctrl+C or Cmd+Tab) do not count as a skip. It also takes the
// step's delayed entrance out of the DOM Turbo snapshots, so coming back with the Back button never replays a blank wait.
// The controller element contains both the overlay and the step. For reduced motion the overlay is removed by CSS.
const MODIFIER_KEYS = ["Shift", "Control", "Alt", "Meta", "AltGraph", "CapsLock", "NumLock", "ScrollLock", "OS"]

export default class extends Controller {
  static targets = ["overlay"]

  skip(event) {
    if (event?.type === "keydown" && (MODIFIER_KEYS.includes(event.key) || event.ctrlKey || event.metaKey || event.altKey)) return

    if (this.hasOverlayTarget) this.overlayTarget.remove()
    this.element.querySelectorAll(".transition-enter").forEach((el) => el.classList.remove("transition-enter"))
  }
}
