import { Controller } from "@hotwired/stimulus"

// The schedule step never asks for a time zone: the browser knows it. On connect, put the browser's IANA zone name in the hidden field that is sent
// with the form. The server maps it to the zone it stores, checks it against its list, and falls back to a safe default if it is missing or unknown.
export default class extends Controller {
  static targets = ["field"]

  connect() {
    const zone = Intl.DateTimeFormat().resolvedOptions().timeZone
    if (zone) this.fieldTarget.value = zone
  }
}
