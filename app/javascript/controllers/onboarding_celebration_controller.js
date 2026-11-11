import { Controller } from "@hotwired/stimulus"

const SOUND_KEY = "battletown:celebration-sound" // "off" when the user muted it, anything else (or nothing) means on
const MASTER_GAIN = 0.2
const POP = { from: 180, to: 50, length: 0.14, peak: 0.9 }
// A rising C major arpeggio, [ frequency in Hz, start in seconds, length in seconds ]. The last note rings longer.
const CHIME = [ [ 523.25, 0.1, 0.6 ], [ 659.25, 0.22, 0.6 ], [ 783.99, 0.34, 0.6 ], [ 1046.5, 0.46, 1 ] ]
const SILENT = 0.0001

// Confetti and its sound are cosmetic: both are skipped for reduced motion and both play once per celebration.
// Browsers only let audio start after a user gesture. The user normally arrives here from a click (Turbo keeps that
// activation), so the sound starts at once; on a fresh load it waits for the first pointer or key press instead.
export default class extends Controller {
  static targets = ["confetti", "sound"]

  connect() {
    this.muted = this.storedMuted()
    this.renderSound()

    const preview = document.documentElement.hasAttribute("data-turbo-preview")
    const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches
    if (preview || reduced || this.element.dataset.celebrated) return

    this.element.dataset.celebrated = "true"
    this.spawnConfetti()
    this.startSound()
  }

  disconnect() {
    this.stopListening()
    this.fadeOutAndClose()
  }

  // Turbo snapshots the page for the Back button: keep the pieces out of it so a restored page does not replay.
  clearConfetti() {
    this.confettiTarget.replaceChildren()
  }

  toggleSound() {
    this.muted = !this.muted
    this.storeMuted()
    this.renderSound()
    if (this.muted && this.master) this.master.gain.setTargetAtTime(0, this.audio.currentTime, 0.02)
  }

  renderSound() {
    this.soundTarget.setAttribute("aria-pressed", String(!this.muted))
    this.soundTarget.querySelector("[data-state]").textContent = this.muted ? "off" : "on"
  }

  storedMuted() {
    try {
      return localStorage.getItem(SOUND_KEY) === "off"
    } catch {
      return false
    }
  }

  storeMuted() {
    try {
      localStorage.setItem(SOUND_KEY, this.muted ? "off" : "on")
    } catch {
      // Private mode or blocked storage: the choice just is not remembered.
    }
  }

  startSound() {
    if (this.muted) return

    try {
      const audio = this.audio = new (window.AudioContext || window.webkitAudioContext)()
      this.unlock = () => audio.resume().then(() => this.play()).catch(() => {})
      this.unlock()
      this.listening = [ "pointerdown", "keydown" ]
      this.listening.forEach((type) => document.addEventListener(type, this.unlock))
    } catch {
      this.audio = null
    }
  }

  stopListening() {
    this.listening?.forEach((type) => document.removeEventListener(type, this.unlock))
    this.listening = null
  }

  play() {
    if (this.played || this.muted || this.audio?.state !== "running") return

    this.played = true
    this.stopListening()
    try {
      const now = this.audio.currentTime
      this.master = this.audio.createGain()
      this.master.gain.value = MASTER_GAIN
      this.master.connect(this.audio.destination)

      this.pop(now)
      CHIME.forEach(([ frequency, start, length ]) => this.chime(frequency, now + start, length))
    } catch {
      // Audio is a bonus: never let it break the page.
    }
  }

  // A short low thump that drops in pitch.
  pop(start) {
    const oscillator = this.audio.createOscillator()
    oscillator.frequency.setValueAtTime(POP.from, start)
    oscillator.frequency.exponentialRampToValueAtTime(POP.to, start + POP.length)
    this.envelope(oscillator, start, POP.length, POP.peak, 0.005)
  }

  // A soft bell: a triangle note plus a quiet sine an octave up.
  chime(frequency, start, length) {
    const body = this.audio.createOscillator()
    body.type = "triangle"
    body.frequency.value = frequency
    this.envelope(body, start, length, 0.5, 0.015)

    const shimmer = this.audio.createOscillator()
    shimmer.frequency.value = frequency * 2
    this.envelope(shimmer, start, length * 0.6, 0.12, 0.015)
  }

  // Soft attack, then an exponential decay to silence.
  envelope(oscillator, start, length, peak, attack) {
    const gain = this.audio.createGain()
    gain.gain.setValueAtTime(SILENT, start)
    gain.gain.linearRampToValueAtTime(peak, start + attack)
    gain.gain.exponentialRampToValueAtTime(SILENT, start + length)
    oscillator.connect(gain).connect(this.master)
    oscillator.start(start)
    oscillator.stop(start + length + 0.05)
  }

  // Leaving the step should not click or leak the context: fade out, then close.
  fadeOutAndClose() {
    const { audio, master } = this
    this.audio = this.master = null
    if (!audio) return

    try {
      master?.gain.setTargetAtTime(0, audio.currentTime, 0.02)
      setTimeout(() => audio.close().catch(() => {}), 150)
    } catch {
      // Already closed.
    }
  }

  spawnConfetti() {
    for (let i = 0; i < 40; i++) {
      const piece = document.createElement("span")
      piece.className = "confetti__piece"
      piece.style.setProperty("--x", `${Math.random() * 100}%`)
      piece.style.setProperty("--delay", `${Math.random() * 1.5}s`)
      piece.style.setProperty("--hue", `${Math.floor(Math.random() * 360)}`)
      this.confettiTarget.append(piece)
    }
  }
}
