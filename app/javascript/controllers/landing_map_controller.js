import { Controller } from "@hotwired/stimulus"

// Draws the path that joins the places on the landing page's map. It is drawn from where things actually sit, so it
// follows the layout at any width, and is redrawn on resize, font load and when an FAQ answer opens or closes.
export default class extends Controller {
  connect() {
    this.connected = true
    this.setUpTrail()
  }

  disconnect() {
    this.connected = false
    if (this.ro) this.ro.disconnect()
    window.removeEventListener("load", this.build)
    window.removeEventListener("resize", this.build)
    if (this.details) this.details.forEach((el) => el.removeEventListener("toggle", this.build))
  }

  setUpTrail() {
    this.svg = this.element.querySelector(".trail")
    if (!this.svg) return
    // The two river banks' edge curves (the same numbers as the edge--c and edge--d paths in the view).
    this.C = [[-20, 150, 300, 172, 600, 46, 900, 62], [900, 62, 1150, 76, 1300, 150, 1460, 118]]
    this.D = [[-20, 58, 250, 150, 600, 150, 900, 92], [900, 92, 1100, 52, 1300, 44, 1460, 84]]
    this.build = this.build.bind(this)
    this.build()
    window.addEventListener("load", this.build)
    window.addEventListener("resize", this.build)
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(() => { if (this.connected) this.build() })
    this.details = this.element.querySelectorAll("details")
    this.details.forEach((el) => el.addEventListener("toggle", this.build))
    if ("ResizeObserver" in window) {
      this.ro = new ResizeObserver(this.build)
      this.ro.observe(this.element)
    }
  }

  box(sel) {
    const L = this.element
    const el = this.element.querySelector(sel)
    let x = 0, y = 0, e = el
    while (e && e !== L) { x += e.offsetLeft; y += e.offsetTop; e = e.offsetParent }
    return { l: x, t: y, w: el.offsetWidth, h: el.offsetHeight, b: y + el.offsetHeight, cx: x + el.offsetWidth / 2 }
  }

  curveY(segs, x) {
    const s = segs[x <= segs[0][6] ? 0 : 1]
    let lo = 0, hi = 1, t = 0.5, u
    for (let k = 0; k < 24; k++) {
      t = (lo + hi) / 2
      u = 1 - t
      if (u*u*u*s[0] + 3*u*u*t*s[2] + 3*u*t*t*s[4] + t*t*t*s[6] < x) lo = t; else hi = t
    }
    u = 1 - t
    return u*u*u*s[1] + 3*u*u*t*s[3] + 3*u*t*t*s[5] + t*t*t*s[7]
  }

  // A smooth run through the points: each stretch leaves and arrives heading straight down, so the bends are plain S-curves
  // with no wobble, and two points with the same x give a straight stretch.
  scurve(p) {
    let d = "M" + p[0][0].toFixed(1) + "," + p[0][1].toFixed(1)
    for (let i = 1; i < p.length; i++) {
      const my = ((p[i - 1][1] + p[i][1]) / 2).toFixed(1)
      d += "C" + p[i - 1][0].toFixed(1) + "," + my + " " + p[i][0].toFixed(1) + "," + my + " " + p[i][0].toFixed(1) + "," + p[i][1].toFixed(1)
    }
    return d
  }

  // The outline of everything on one side of a river bank, so the path can be cut off cleanly along the bank's curve.
  bankClip(segs, top, height, units, W, H, above) {
    const pts = []
    for (let i = 0; i <= 48; i++) {
      const x = W * i / 48
      pts.push(x.toFixed(1) + "," + (top - height * (1 - this.curveY(segs, x / W * 1440) / units)).toFixed(1))
    }
    return pts.join(" ") + (above ? " " + W + ",0 0,0" : " " + W + "," + H + " 0," + H)
  }

  build() {
    if (!this.connected) return
    const L = this.element, svg = this.svg, C = this.C, D = this.D
    const W = L.offsetWidth, H = L.offsetHeight, wide = W >= 1024
    svg.setAttribute("viewBox", "0 0 " + W + " " + H)
    const sp = this.box(".signpost"), ft = this.box(".fight .in"), ar = this.box(".arena"), pz = this.box(".prizes .in"), sh = this.box(".shelf"), fq = this.box(".faq .in"), fi = this.box(".final .in"), or = this.box(".final__orpheus")
    const h3 = this.box(".hop--3"), hl = this.box(wide ? ".hop--5" : ".hop--4")
    const ec = L.querySelector(".edge--c").getBoundingClientRect().height, ed = L.querySelector(".edge--d").getBoundingClientRect().height
    const bankC = fq.t - ec * (1 - this.curveY(C, h3.cx / W * 1440) / 200) + 2
    const bankD = fi.t - ed * (1 - this.curveY(D, hl.cx / W * 1440) / 180) + 2
    const p0 = [sp.cx, sp.b - sp.h * 0.024], over = 60 // the path runs a little past each bank and is cut off along it
    let main, last
    if (wide) {
      const gap = Math.min(W * 0.04, 56), jx = ar.l - gap, side = parseFloat(getComputedStyle(L.querySelector(".prizes .wrap")).paddingLeft), mx = W - side / 2
      // Beside the prizes the path sways from side to side within the margin, so it never runs dead straight.
      const sway = Math.max(8, Math.min(side * 0.2, 30)), y1 = sh.t + gap * 0.3, y2 = sh.b - gap * 0.6
      main = [p0, [jx, ar.t + ar.h * 0.55], [mx + sway, y1], [mx - sway, (y1 + y2) / 2], [mx + sway * 0.6, y2], [h3.cx, bankC + over]]
      last = [[hl.cx, bankD - over], [or.l + or.w * 0.42, or.t + or.h * 0.8]]
    } else {
      main = [p0, [W * 0.88, ft.t + W * 0.24], [W * 0.8, ar.t + ar.h * 0.55], [W * 0.91, pz.t + W * 0.14], [W * 0.84, sh.t + sh.h * 0.4], [W * 0.91, sh.b - W * 0.2], [h3.cx, bankC + over]]
      last = [[hl.cx, bankD - over], [or.l + or.w * 0.5, or.t + or.h * 0.6]]
    }
    const d = [this.scurve(main), this.scurve(last)]
    svg.querySelectorAll("path").forEach((p, i) => { p.setAttribute("d", d[i]) })
    const clips = svg.querySelectorAll("polygon")
    clips[0].setAttribute("points", this.bankClip(C, fq.t, ec, 200, W, H, true))
    clips[1].setAttribute("points", this.bankClip(D, fi.t, ed, 180, W, H, false))
  }
}
