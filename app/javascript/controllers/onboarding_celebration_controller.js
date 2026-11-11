import { Controller } from "@hotwired/stimulus"

const MUTE_KEY = "battletown:muted"
const FANFARE = [ [ 523.25, 0 ], [ 659.25, 0.12 ], [ 783.99, 0.24 ], [ 1046.5, 0.36 ] ]

// Confetti is cosmetic and skipped for reduced motion. Sound only ever starts from a click, and a mute choice is remembered.
export default class extends Controller {
  static targets = ["confetti", "mute"]

  connect() {
    this.muted = localStorage.getItem(MUTE_KEY) === "1"
    this.renderMute()
    if (!matchMedia("(prefers-reduced-motion: reduce)").matches) this.spawnConfetti()
  }

  disconnect() {
    this.audio?.close()
  }

  toggleMute() {
    this.muted = !this.muted
    localStorage.setItem(MUTE_KEY, this.muted ? "1" : "0")
    this.renderMute()
  }

  fanfare() {
    if (this.muted) return

    this.audio ||= new AudioContext()
    FANFARE.forEach(([ frequency, delay ]) => this.blip(frequency, this.audio.currentTime + delay))
  }

  blip(frequency, start) {
    const oscillator = this.audio.createOscillator()
    const gain = this.audio.createGain()
    oscillator.type = "square"
    oscillator.frequency.value = frequency
    gain.gain.setValueAtTime(0.08, start)
    gain.gain.exponentialRampToValueAtTime(0.001, start + 0.2)
    oscillator.connect(gain).connect(this.audio.destination)
    oscillator.start(start)
    oscillator.stop(start + 0.2)
  }

  renderMute() {
    this.muteTarget.setAttribute("aria-pressed", String(this.muted))
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
