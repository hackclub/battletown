import { Controller } from "@hotwired/stimulus"

// Asks "are you sure?" before a form is submitted, for forms that turn Turbo off (so turbo-confirm cannot do it).
//   <form data-controller="confirm" data-confirm-message-value="..." data-action="submit->confirm#ask">
export default class extends Controller {
  static values = { message: String }

  ask(event) {
    if (!window.confirm(this.messageValue)) event.preventDefault()
  }
}
