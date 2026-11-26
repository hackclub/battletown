import { Controller } from "@hotwired/stimulus"

// Keeps the boss stage on the dashboard live (app/views/dashboard/_stage.html.erb). Every 30 seconds, while the tab is visible, it asks
// GET /boss/fighters (Bosses::Presenter#live_payload) and redraws from the answer:
//
// - the FIGHTERS: one circle per person who coded in the last 24 hours (at most 12), found again by their key. A new one pops in, one
//   that left shrinks away, and a changed one just gets other classes (its size and its hit), so the CSS transitions glide it there.
//   A circle keeps the place (stage__fan--pN) it first got, so nobody jumps around when somebody else comes or goes.
//   Each circle also has its own rhythm (start offset, speed, bob, lunge): the payload's `motion` steps become classes (stage__fan--da3,
//   see Bosses::FighterMotion and dashboard.css; the CSP has no style attributes). They are put on once, when the circle is built, and a
//   redraw never touches them, so a circle that stays keeps its animation running and nobody falls back into step.
// - the boss's health bar, its two plates, the visually hidden summary and arena sentence
//   (which says so in words when nobody coded; nothing about an empty arena is drawn on screen).
//
// It listens for a window event "boss:refresh" (the development event simulator sends it after every action) and refreshes at once.
// It pauses while the tab is hidden and refreshes the moment the tab is back; a failed or refused request backs the next one off
// (30 s, 1 min, 2 min ... at most 5 min); it stops for good when the answer is not the JSON (signed out) and when the page goes away
// (disconnect, or before Turbo caches the page). Requests are never closer than MIN_GAP_MS, which keeps well under the endpoint's
// limit of about 12 a minute however often "boss:refresh" fires.
//
// Live pushes (boss_live_controller.js, Bosses::Live) arrive as "boss-live:draw" with a payload shaped like the poll's, and are drawn the same way.
// While the socket is up ("boss-live:state" live) the poll only reconciles every LIVE_POLL_MS (a safety net for a message that never came);
// when it is down the poll is the 30-second one again, and a reconnect asks once at once.
//
// Everything from the server goes in with createElement, textContent and setAttribute, never as markup.
const POLL_MS = 30_000
const MIN_GAP_MS = 5_000
const LIVE_POLL_MS = 120_000 // the poll while the socket is healthy: a reconcile, not the main way the stage updates
const MAX_BACKOFF_MS = 300_000
const SLOTS = 12 // places around the boss (stage__fan--p1 to p12), the most circles the page draws
const LEAVE_MS = 400
const ENTER_MS = 500
const STATES = ["in-progress", "defeated", "escaped", "none"]
const MOTION_STEPS = { da: 8, db: 12, dc: 6, de: 10, ba: 4, la: 8, lb: 7 } // how many steps each has (Bosses::FighterMotion::STEPS)
const MANAGED_CLASS = /^stage__fan--(s\d|hit-\w+|you)$/

export default class extends Controller {
  static targets = ["crowd", "bar", "healthText", "summary", "plate", "name", "arena"]
  static values = { url: String }

  connect() {
    this.stopped = false
    this.failures = 0
    this.lastAt = 0
    this.inFlight = false
    this.again = false
    this.onVisibility = () => (document.hidden ? this.clearTimers() : this.refresh())
    this.onRefresh = () => this.refresh()
    this.onKeydown = (event) => event.key === "Escape" && this.dismissCard()
    this.onPoint = (event) => this.showCards(event.target.closest?.(".stage__fan"))
    this.live = false
    this.onLiveDraw = (event) => this.draw(event.detail)
    this.onLiveState = (event) => this.liveState(event.detail)
    this.element.addEventListener("boss-live:draw", this.onLiveDraw)
    this.element.addEventListener("boss-live:state", this.onLiveState)
    document.addEventListener("visibilitychange", this.onVisibility)
    document.addEventListener("keydown", this.onKeydown)
    window.addEventListener("boss:refresh", this.onRefresh)
    if (this.hasCrowdTarget) ["pointerover", "focusin"].forEach((name) => this.crowdTarget.addEventListener(name, this.onPoint))
    this.schedule()
  }

  disconnect() {
    this.stop()
  }

  // Stop for good: no timers, no request in flight, no listeners, and no half-way animation left in the page Turbo is about to cache.
  stop() {
    this.stopped = true
    this.clearTimers()
    this.abort?.abort()
    document.removeEventListener("visibilitychange", this.onVisibility)
    document.removeEventListener("keydown", this.onKeydown)
    window.removeEventListener("boss:refresh", this.onRefresh)
    if (this.hasCrowdTarget) ["pointerover", "focusin"].forEach((name) => this.crowdTarget.removeEventListener(name, this.onPoint))
    this.element.removeEventListener("boss-live:draw", this.onLiveDraw)
    this.element.removeEventListener("boss-live:state", this.onLiveState)
    clearTimeout(this.hitTimer)
    if (this.hasBarTarget) this.barTarget.classList.remove("stage__bar--hit")
    if (this.hasCrowdTarget) {
      this.crowdTarget.querySelectorAll(".stage__fan--leaving").forEach((element) => element.remove())
      this.crowdTarget.querySelectorAll(".stage__fan--entering").forEach((element) => element.classList.remove("stage__fan--entering"))
    }
  }

  // Escape puts the open card away (it can cover other circles) until the pointer or focus reaches another circle (WCAG 1.4.13).
  dismissCard() {
    if (!this.hasCrowdTarget) return
    this.dismissedFan = this.crowdTarget.querySelector(".stage__fan:hover") || document.activeElement?.closest?.(".stage__fan")
    if (this.dismissedFan) this.crowdTarget.dataset.tipsHidden = ""
  }

  showCards(fan) {
    if (!this.hasCrowdTarget || !("tipsHidden" in this.crowdTarget.dataset) || fan === this.dismissedFan) return
    delete this.crowdTarget.dataset.tipsHidden
  }

  clearTimers() {
    clearTimeout(this.pollTimer)
    clearTimeout(this.gapTimer)
  }

  // The next poll: 30 s after the last answer, doubling with every failure in a row.
  schedule() {
    this.clearTimers()
    if (this.stopped || document.hidden) return
    const delay = this.live ? LIVE_POLL_MS : Math.min(POLL_MS * 2 ** this.failures, MAX_BACKOFF_MS)
    this.pollTimer = setTimeout(() => this.refresh(), delay)
  }

  // The socket came up or went down (boss_live_controller.js). A reconnect (`catchUp`) and a drop ask for the stage right away.
  liveState({ live, catchUp }) {
    if (this.stopped) return
    this.live = Boolean(live)
    if (catchUp || !this.live) this.refresh()
    else this.schedule()
  }

  // Ask now (or as soon as MIN_GAP_MS since the last request allows, and after the one in flight).
  refresh() {
    if (this.stopped || document.hidden) return
    clearTimeout(this.pollTimer)
    if (this.inFlight) {
      this.again = true
      return
    }
    const wait = this.lastAt + MIN_GAP_MS - Date.now()
    if (wait > 0) {
      clearTimeout(this.gapTimer)
      this.gapTimer = setTimeout(() => this.refresh(), wait)
      return
    }
    this.load()
  }

  async load() {
    this.inFlight = true
    this.lastAt = Date.now()
    this.abort = new AbortController()
    try {
      // "no-cache": the browser asks the server every time (it answers 304 by ETag when nothing changed) and hands over the body.
      const response = await fetch(this.urlValue, { headers: { Accept: "application/json" }, credentials: "same-origin", cache: "no-cache", signal: this.abort.signal })
      const json = response.ok && !response.redirected && (response.headers.get("Content-Type") || "").includes("json")
      if (json) {
        this.draw(await response.json())
        this.failures = 0
      } else if (response.status === 429 || response.status >= 500) {
        this.failures += 1
      } else {
        this.stop() // signed out, not onboarded or gone: nothing to keep asking
        return
      }
    } catch (error) {
      if (error.name === "AbortError") return
      this.failures += 1
    } finally {
      this.inFlight = false
    }
    if (this.stopped) return
    if (this.again) {
      this.again = false
      this.refresh()
    } else {
      this.schedule()
    }
  }

  // ---- drawing ----

  draw(data) {
    if (typeof data.damage_text === "string") this.element.dataset.damageText = data.damage_text // the viewer's own sentence, kept for live pushes
    this.element.classList.remove(...STATES.map((name) => `stage--${name}`))
    this.element.classList.add(`stage--${String(data.state).replaceAll("_", "-")}`)
    this.setBar(data)
    this.setText(this.hasHealthTextTarget && this.healthTextTarget, data.health_text)
    this.setText(this.hasSummaryTarget && this.summaryTarget, data.summary)
    this.setText(this.hasPlateTarget && this.plateTarget, data.health_text)
    this.setText(this.hasNameTarget && this.nameTarget, data.boss_name)
    this.setText(this.hasArenaTarget && this.arenaTarget, data.arena_text)
    if (this.hasCrowdTarget) this.drawFighters(Array.isArray(data.fighters) ? data.fighters.slice(0, SLOTS) : [])
  }

  setText(element, value) {
    if (element && typeof value === "string" && element.textContent !== value) element.textContent = value
  }

  setBar(data) {
    if (!this.hasBarTarget) return
    const percent = Number(data.health_percent)
    if (Number.isFinite(percent)) {
      const next = Math.min(100, Math.max(0, percent))
      if (next < this.barTarget.value) this.hit()
      this.barTarget.value = next
    }
    if (typeof data.health_text === "string") this.barTarget.textContent = data.health_text
  }

  // The boss took damage: a short flash on its bar (motion only; the bar itself glides by its CSS transition).
  hit() {
    if (!this.motion()) return
    this.barTarget.classList.remove("stage__bar--hit")
    void this.barTarget.offsetWidth // lets the same animation start again
    this.barTarget.classList.add("stage__bar--hit")
    clearTimeout(this.hitTimer)
    this.hitTimer = setTimeout(() => this.barTarget.classList.remove("stage__bar--hit"), 700)
  }

  drawFighters(fighters) {
    const crowd = this.crowdTarget
    const present = new Map()
    crowd.querySelectorAll(":scope > .stage__fan").forEach((li) => {
      if (!li.classList.contains("stage__fan--leaving")) present.set(li.dataset.fighterKey, li)
    })
    const wanted = new Set(fighters.map((fighter) => fighter.key))
    present.forEach((li, key) => {
      if (!wanted.has(key)) this.leave(li)
    })
    // Places in use: the ones kept and the ones still shrinking away.
    const used = new Set([...crowd.querySelectorAll(":scope > .stage__fan")].map((li) => this.slotOf(li)))
    fighters.forEach((fighter) => {
      const li = present.get(fighter.key)
      if (li && li.dataset.linked !== (this.linkOf(fighter) ? "1" : "0")) {
        // Became (or stopped being) a link: swap only the circle inside, so the <li> and its running animation stay as they are.
        const old = li.querySelector(".stage__fighter")
        const hadFocus = old.contains(document.activeElement)
        const circle = this.buildCircle(fighter)
        old.replaceWith(circle)
        if (hadFocus) circle.focus({ preventScroll: true }) // the keyboard user keeps their place
        li.dataset.linked = this.linkOf(fighter) ? "1" : "0"
        this.fill(li, fighter)
      } else if (li) {
        this.fill(li, fighter)
      } else {
        const slot = this.freeSlot(used)
        used.add(slot)
        const fresh = this.build(fighter, slot)
        this.enter(fresh)
        crowd.appendChild(fresh)
      }
    })
  }

  slotOf(li) {
    const match = [...li.classList].map((name) => name.match(/^stage__fan--p(\d+)$/)).find(Boolean)
    return match ? Number(match[1]) : 0
  }

  freeSlot(used) {
    for (let slot = 1; slot <= SLOTS; slot++) if (!used.has(slot)) return slot
    return 1
  }

  linkOf(fighter) {
    return typeof fighter.path === "string" && fighter.path.startsWith("/players/") ? fighter.path : null
  }

  // The address of a player's Slack picture (this app's own copy, never Slack), only when it has exactly the shape the server makes.
  avatarOf(fighter) {
    const url = fighter.avatar_url
    return typeof url === "string" && /^\/players\/[a-z0-9]{10,12}\/avatar\?v=[0-9a-f]{1,10}$/.test(url) ? url : null
  }

  // The picture in place of the initial, or the initial again when there is no picture (turned off, deleted, not fetched).
  setAvatar(circle, fighter) {
    const url = this.avatarOf(fighter)
    let image = circle.querySelector("img.avatar__img")
    if (!url) {
      if (image) circle.textContent = fighter.initial || ""
      return
    }
    if (!image) {
      circle.textContent = ""
      image = document.createElement("img")
      image.className = "avatar__img"
      image.alt = ""
      image.width = 128
      image.height = 128
      image.draggable = false
      image.decoding = "async"
      circle.appendChild(image)
    }
    if (image.getAttribute("src") !== url) image.setAttribute("src", url)
  }

  motion() {
    return window.matchMedia("(prefers-reduced-motion: no-preference)").matches
  }

  enter(li) {
    if (!this.motion()) return
    li.classList.add("stage__fan--entering")
    setTimeout(() => li.classList.remove("stage__fan--entering"), ENTER_MS)
  }

  // Someone is leaving the stage: if the keyboard focus is on them, hand it to the next circle (or the list) first, so it never drops to the
  // top of the page.
  releaseFocus(li) {
    if (!li.contains(document.activeElement)) return
    const next = [li.nextElementSibling, li.previousElementSibling].find((sibling) => sibling?.matches(".stage__fan:not(.stage__fan--leaving)"))
    ;(next?.querySelector(".stage__fighter") || this.crowdTarget).focus({ preventScroll: true })
  }

  leave(li) {
    this.releaseFocus(li)
    if (!this.motion()) {
      li.remove()
      return
    }
    li.classList.add("stage__fan--leaving")
    setTimeout(() => li.remove(), LEAVE_MS)
  }

  // The same markup as app/views/dashboard/_fighter.html.erb.
  build(fighter, slot) {
    const href = this.linkOf(fighter)
    const tipId = `fighter-tip-${fighter.key}`
    const li = document.createElement("li")
    li.dataset.fighterKey = fighter.key
    li.dataset.linked = href ? "1" : "0"
    li.className = ["stage__fan", `stage__fan--p${slot}`, ...this.motionClasses(fighter)].join(" ")
    li.appendChild(this.buildCircle(fighter))

    const tip = document.createElement("span")
    tip.className = "stage__tip"
    tip.id = tipId
    tip.setAttribute("aria-hidden", "true") // the circle's aria-label says the same words
    const title = document.createElement("strong")
    title.className = "stage__tip-title"
    tip.appendChild(title)
    ;["detail", "status", "hint"].forEach((name) => {
      const line = document.createElement("span")
      line.dataset.line = name
      if (name === "hint") line.className = "stage__tip-hint"
      tip.appendChild(line)
    })
    li.appendChild(tip)

    this.fill(li, fighter)
    return li
  }

  // One person's own rhythm as classes (stage__fan--da3 ...): a whole number in each step's range, or the middle of the range when the
  // payload has none, so a circle never ends up with no class of a kind.
  motionClasses(fighter) {
    const motion = fighter.motion && typeof fighter.motion === "object" ? fighter.motion : {}
    return Object.entries(MOTION_STEPS).map(([name, count]) => {
      const step = Number.isInteger(motion[name]) ? motion[name] : Math.floor(count / 2)
      return `stage__fan--${name}${Math.min(count - 1, Math.max(0, step))}`
    })
  }

  // The circle itself: a link to their profile, or a plain circle you can focus.
  buildCircle(fighter) {
    const href = this.linkOf(fighter)
    let circle
    if (href) {
      circle = document.createElement("a")
      circle.href = href
      circle.className = `stage__fighter avatar avatar--tone-${Math.min(11, Math.max(0, Number(fighter.tone) || 0))}`
      circle.textContent = fighter.initial || ""
    } else {
      circle = document.createElement("span")
      circle.className = "stage__fighter stage__fighter--anonymous"
      circle.tabIndex = 0
      circle.setAttribute("role", "img")
    }
    return circle
  }

  // Put one person's current words and classes on their circle (size and hit are classes, so the CSS transitions animate the change).
  fill(li, fighter) {
    ;[...li.classList].filter((name) => MANAGED_CLASS.test(name)).forEach((name) => li.classList.remove(name))
    li.classList.add(`stage__fan--s${Math.min(5, Math.max(1, Number(fighter.size) || 1))}`)
    if (fighter.tier === "ship" || fighter.tier === "code") li.classList.add(`stage__fan--hit-${fighter.tier}`)
    if (fighter.you) li.classList.add("stage__fan--you")

    const circle = li.querySelector(".stage__fighter")
    circle.setAttribute("aria-label", String(fighter.label || ""))
    if (li.dataset.linked === "1") this.setAvatar(circle, fighter)
    const tip = li.querySelector(".stage__tip")
    this.setText(tip.querySelector(".stage__tip-title"), String(fighter.title || ""))
    ;["detail", "status", "hint"].forEach((name) => {
      const line = tip.querySelector(`[data-line="${name}"]`)
      this.setText(line, String(fighter[name] || ""))
      line.hidden = !fighter[name]
    })

    const marker = li.querySelector(".stage__you")
    if (fighter.you && !marker) {
      const you = document.createElement("span")
      you.className = "stage__you"
      you.setAttribute("aria-hidden", "true")
      you.textContent = "you"
      li.insertBefore(you, tip)
    } else if (!fighter.you && marker) {
      marker.remove()
    }
  }
}
