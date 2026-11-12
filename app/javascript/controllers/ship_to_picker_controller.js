import { Controller } from "@hotwired/stimulus"

// The address step's dropdown. Shows the preview of the chosen address and enables the submit button only once an address is
// chosen. It never reads or sends address text: the form posts the chosen address id only, and the server looks it up.
export default class extends Controller {
  static targets = ["select", "preview", "submit"]

  connect() {
    this.choose()
  }

  choose() {
    const id = this.hasSelectTarget ? this.selectTarget.value : ""
    this.previewTargets.forEach((preview) => {
      preview.hidden = preview.dataset.addressId !== id
    })
    if (this.hasSubmitTarget) this.submitTarget.disabled = id === ""
  }
}
