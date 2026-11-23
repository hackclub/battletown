import { Controller } from "@hotwired/stimulus"

// The idea box on the project step: a live counter and the "spark" chips above it. A chip never throws away what
// the teen typed: it fills an empty box, swaps one suggestion for another, and otherwise adds itself on a new line.
export default class extends Controller {
  static targets = ["field", "counter", "count", "excess"]
  static values = { max: Number }
  static classes = ["over"]

  connect() {
    this.count()
  }

  fill({ params: { text } }) {
    const field = this.fieldTarget
    const lines = this.lines(field.value)

    if (lines.length === 0 || lines.every((line) => this.suggestions.includes(line))) {
      // Empty, or only suggestions so far (their own words would stay): the new one takes over.
      if (!(lines.length === 1 && lines[0] === text)) this.write(text, true)
    } else if (!lines.includes(text)) {
      const addition = field.value.endsWith("\n") ? text : `\n${text}`
      if (this.length(`${field.value}${addition}`) <= this.maxValue) this.write(addition, false)
    }
    field.focus()
    field.setSelectionRange(field.value.length, field.value.length)
    this.count()
  }

  count() {
    const length = this.length(this.fieldTarget.value)
    const excess = length - this.maxValue
    this.countTarget.textContent = length
    // The limit is said in words, not only shown in colour. The counter is not a live region: it is read when the box is
    // focused (aria-describedby), so typing never chatters.
    this.excessTarget.textContent = excess > 0 ? `, too long by ${excess}` : ""
    this.counterTarget.classList.toggle(this.overClass, excess > 0)
  }

  // Every chip's text, so a box holding only suggestions can be told apart from one holding the teen's words.
  get suggestions() {
    return Array.from(this.element.querySelectorAll("[data-onboarding-idea-text-param]"), (chip) => chip.dataset.onboardingIdeaTextParam)
  }

  lines(value) {
    return value.split("\n").map((line) => line.trim()).filter(Boolean)
  }

  // Typed through the editing machinery where the browser allows it, so Ctrl+Z / Cmd+Z still undoes a chip tap.
  write(text, replaceAll) {
    const field = this.fieldTarget
    const expected = replaceAll ? text : `${field.value}${text}`
    field.focus()
    field.setSelectionRange(replaceAll ? 0 : field.value.length, field.value.length)
    document.execCommand("insertText", false, text)
    if (field.value !== expected) field.value = expected
  }

  // The length the server will see: characters (not UTF-16 units), after the same whitespace strip Ruby does,
  // with each line break counted as the two characters (CRLF) a browser submits for it.
  length(value) {
    const trimmed = value.replace(/^[\0\t\n\v\f\r ]+|[\0\t\n\v\f\r ]+$/g, "")
    return Array.from(trimmed).length + (trimmed.match(/\n/g) || []).length
  }
}
