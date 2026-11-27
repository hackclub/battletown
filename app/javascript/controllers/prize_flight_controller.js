import { Controller } from "@hotwired/stimulus"

// On the prize step: when the form is sent, remember where the picked card's picture is, so the next step's docked prize can fly in from there.
// Nothing is saved but a rectangle and the prize key, in sessionStorage; the server still holds the pick.
export default class extends Controller {
  record() {
    const picked = this.element.querySelector("input[name='user[prize_key]']:checked")
    const art = picked?.closest(".choice")?.querySelector(".choice__art")
    if (!picked || !art) return
    const r = art.getBoundingClientRect()
    sessionStorage.setItem("battletown-prize-flight", JSON.stringify({ key: picked.value, x: r.x, y: r.y, w: r.width, h: r.height }))
  }
}
