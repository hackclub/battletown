import { Controller } from "@hotwired/stimulus"

// The optional "Different time on some days?" rows on the schedule step. The server renders a row for all seven days
// (so without JavaScript the form still works) and drops a time for a day that is not selected. This shows only the
// rows for the selected day pills and disables the others so they are not submitted; what was typed in a row is kept,
// so ticking a day again brings its time back. A blank row means "use the usual time" and is never filled in here.
// The day pills stay the source of truth: nothing is read from, or written to, their checked state.
export default class extends Controller {
  static targets = ["day", "row"]

  connect() {
    this.sync()
  }

  sync() {
    const selected = new Set(this.dayTargets.filter((day) => day.checked).map((day) => day.value))
    this.rowTargets.forEach((row) => {
      const show = selected.has(row.dataset.day)
      row.hidden = !show
      row.querySelector("input").disabled = !show
    })
  }
}
