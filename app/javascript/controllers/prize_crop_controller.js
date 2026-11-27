import { Controller } from "@hotwired/stimulus"

// A product picture with wide transparent margins reads small next to one that fills its frame. When the picture has loaded, this finds the box of
// its visible (non-transparent) pixels on a small canvas and, if the margins are worth removing, sets the crop as custom properties on its wrapper
// and turns the crop on (CSS: .choice__crop--measured). Same-origin pictures only; a picture that cannot be read, or has no real margin, is left whole.
const SIZE = 128
const ALPHA = 24
const MIN_MARGIN = 0.06 // crop only when at least this much of a side is empty

export default class extends Controller {
  static targets = ["image"]

  connect() {
    if (this.imageTarget.complete && this.imageTarget.naturalWidth) this.measure()
    else this.imageTarget.addEventListener("load", () => this.measure(), { once: true })
  }

  measure() {
    const img = this.imageTarget
    const scale = SIZE / Math.max(img.naturalWidth, img.naturalHeight)
    const w = Math.max(1, Math.round(img.naturalWidth * scale)), h = Math.max(1, Math.round(img.naturalHeight * scale))
    let data
    try {
      const canvas = document.createElement("canvas")
      canvas.width = w; canvas.height = h
      const ctx = canvas.getContext("2d", { willReadFrequently: true })
      ctx.drawImage(img, 0, 0, w, h)
      data = ctx.getImageData(0, 0, w, h).data
    } catch (_error) { return }
    let x0 = w, y0 = h, x1 = -1, y1 = -1
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) if (data[(y * w + x) * 4 + 3] > ALPHA) {
      if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y
    }
    if (x1 < 0) return
    const fw = (x1 - x0 + 1) / w, fh = (y1 - y0 + 1) / h
    if (fw > 1 - MIN_MARGIN && fh > 1 - MIN_MARGIN) return
    const set = (name, value) => this.element.style.setProperty(name, value.toFixed(4))
    set("--ar", ((x1 - x0 + 1) * img.naturalWidth / w) / ((y1 - y0 + 1) * img.naturalHeight / h))
    set("--fw", fw); set("--fh", fh); set("--fx", x0 / w); set("--fy", y0 / h)
    this.element.classList.add("choice__crop--measured")
  }
}
