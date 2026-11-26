import { Controller } from "@hotwired/stimulus"

// A searchable multi-select dropdown made of a native <details> and a list of checkboxes. The search box narrows the list,
// the summary says what is ticked, Escape or a click outside closes it. Without JavaScript the list stays open and every
// checkbox works as a normal form field; the search box only appears once this runs.
export default class extends Controller {
  static targets = ["box", "summary", "filter", "option", "empty", "status"]

  connect() {
    this.filterTarget.hidden = false
    this.boxTarget.open = false
    this.count()
    this.outside = (event) => { if (!this.element.contains(event.target)) this.boxTarget.open = false }
    this.escape = (event) => {
      if (event.key === "Escape" && this.boxTarget.open) {
        this.boxTarget.open = false
        this.summaryTarget.focus()
      }
    }
    document.addEventListener("click", this.outside)
    this.element.addEventListener("keydown", this.escape)
    this.boxTarget.addEventListener("toggle", () => { if (this.boxTarget.open) this.filterTarget.focus() })
  }

  disconnect() {
    document.removeEventListener("click", this.outside)
    this.element.removeEventListener("keydown", this.escape)
  }

  filter() {
    const query = this.filterTarget.value.trim().toLowerCase()
    let shown = 0
    this.optionTargets.forEach((option) => {
      const match = option.dataset.name.includes(query)
      option.hidden = !match
      if (match) shown += 1
    })
    this.emptyTarget.hidden = shown > 0
  }

  // Enter in the search box must not submit the form.
  ignoreEnter(event) {
    event.preventDefault()
  }

  count() {
    const names = this.optionTargets.map((option) => option.querySelector("input")).filter((box) => box.checked).map((box) => box.dataset.label)
    this.summaryTarget.textContent = names.length === 0 ? "Choose projects" : names.length <= 2 ? names.join(", ") : `${names.length} projects chosen`
    this.statusTarget.textContent = names.length === 0 ? "Pick every Hackatime project that belongs to this one." : `${names.length} chosen: ${names.join(", ")}`
  }
}
