import { Controller } from "@hotwired/stimulus"

// The "which editor do you use" question on the Hackatime step. The server renders every editor's steps (so without
// JavaScript they all show); with JavaScript only the chosen editor's steps are shown. The choice is not sent anywhere: it is
// remembered for this tab only, so it is still there when Hackatime sends the person back to this page.
export default class extends Controller {
  static targets = ["choice", "panel"]
  static values = { storageKey: { type: String, default: "battletown-onboarding-editor" } }

  connect() {
    this.element.classList.add("is-scripted")
    const saved = this.read()
    const match = saved && this.choiceTargets.find((choice) => choice.value === saved)
    if (match) match.checked = true
    this.show()
  }

  choose() {
    const picked = this.choiceTargets.find((choice) => choice.checked)
    if (picked) this.write(picked.value)
    this.show()
  }

  show() {
    const picked = this.choiceTargets.find((choice) => choice.checked)?.value
    this.panelTargets.forEach((panel) => { panel.hidden = panel.dataset.editor !== picked })
  }

  read() {
    try { return window.sessionStorage.getItem(this.storageKeyValue) } catch { return null }
  }

  write(value) {
    try { window.sessionStorage.setItem(this.storageKeyValue, value) } catch { /* private mode: the choice just is not remembered */ }
  }
}
