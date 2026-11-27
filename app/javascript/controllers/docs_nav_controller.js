import { Controller } from "@hotwired/stimulus"

// The docs page's contents list. It marks the link of the section being read (aria-current), and on narrow screens folds the
// list into its closed <details> (the server leaves it open, so without JavaScript the list is simply always visible).
export default class extends Controller {
  static targets = ["details", "link"]
  static values = { wide: { type: String, default: "(min-width: 62rem)" } }

  connect() {
    this.media = window.matchMedia(this.wideValue)
    this.fold = () => { this.detailsTarget.open = this.media.matches }
    this.media.addEventListener("change", this.fold)
    this.fold()

    this.sections = this.linkTargets.map((link) => document.getElementById(link.hash.slice(1))).filter(Boolean)
    if (!("IntersectionObserver" in window) || this.sections.length === 0) return

    // A heading counts as current once it passes the top fifth of the window, until the next one does.
    this.visible = new Set()
    this.observer = new IntersectionObserver((entries) => {
      entries.forEach((entry) => (entry.isIntersecting ? this.visible.add(entry.target) : this.visible.delete(entry.target)))
      this.mark()
    }, { rootMargin: "0px 0px -80% 0px" })
    this.sections.forEach((section) => this.observer.observe(section))
    this.scroller = () => this.mark()
    window.addEventListener("scroll", this.scroller, { passive: true })
    this.mark()
  }

  disconnect() {
    this.media?.removeEventListener("change", this.fold)
    this.observer?.disconnect()
    if (this.scroller) window.removeEventListener("scroll", this.scroller)
  }

  // The last heading that is above the line a fifth of the way down the window.
  mark() {
    const line = window.innerHeight * 0.2
    let current = null
    this.sections.forEach((section) => { if (section.getBoundingClientRect().top <= line) current = section })
    this.linkTargets.forEach((link) => {
      if (current && link.hash === `#${current.id}`) link.setAttribute("aria-current", "location")
      else link.removeAttribute("aria-current")
    })
  }
}
