import { Controller } from "@hotwired/stimulus"

// Places the 15-minute mark on the daily goal bar on the dashboard. The mark sits at percent / 100 of the bar's
// width. Styles cannot be inline under the CSP, so the position is set as a custom property through the style API
// (allowed), and the mark only shows once it is placed. Without JavaScript the bar and its words are all there is.
export default class extends Controller {
  static values = { percent: Number }

  connect() {
    const percent = Math.min(Math.max(this.percentValue, 0), 100)
    this.element.style.setProperty("--mark", percent)
    this.element.classList.add("is-marked")
  }
}
