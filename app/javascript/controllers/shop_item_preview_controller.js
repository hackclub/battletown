import { Controller } from "@hotwired/stimulus"

// The live preview card on the admin shop item form. It copies what staff type (name, description, emoji, price, tier) into the
// card, which has the shop's own markup, and shows a chosen picture before it is saved. Progressive enhancement: the card is
// already rendered by the server from the saved item, and saving the form works without this.
export default class extends Controller {
  static targets = ["name", "description", "emoji", "price", "tier", "image", "hours",
                    "nameInput", "descriptionInput", "emojiInput", "coinsInput", "tierInput", "fileInput", "removeInput"]
  static values = { coinsPerHour: { type: Number, default: 10 } }

  connect() {
    this.savedImage = this.hasImageTarget && !this.imageTarget.hidden ? this.imageTarget.getAttribute("src") : null
    this.picked = null
    this.update()
  }

  update() {
    if (this.hasNameInputTarget) this.nameTarget.textContent = this.nameInputTarget.value.trim() || "Item name"
    if (this.hasDescriptionInputTarget) this.descriptionTarget.textContent = this.descriptionInputTarget.value.trim() || "A line about the item."
    if (this.hasEmojiInputTarget) this.emojiTarget.textContent = this.emojiInputTarget.value.trim()
    if (this.hasCoinsInputTarget) {
      const coins = parseInt(this.coinsInputTarget.value, 10) || 0
      this.priceTarget.textContent = `${coins.toLocaleString("en-US")} ${coins === 1 ? "coin" : "coins"}`
      if (this.hasHoursTarget) this.hoursTarget.textContent = this.hoursText(coins)
    }
    if (this.hasTierInputTarget) {
      const tier = this.tierInputTarget.value
      this.tierTarget.textContent = tier.charAt(0).toUpperCase() + tier.slice(1)
      this.tierTarget.hidden = tier === "shop"
    }
    this.showArt()
  }

  // A chosen file is shown straight from the browser (a data: URL, which the CSP allows for images); nothing is uploaded yet.
  pick() {
    const file = this.hasFileInputTarget ? this.fileInputTarget.files[0] : null
    if (!file || !file.type.startsWith("image/")) {
      this.picked = null
      return this.update()
    }
    const reader = new FileReader()
    reader.onload = () => { this.picked = reader.result; this.update() }
    reader.readAsDataURL(file)
  }

  showArt() {
    const removed = this.hasRemoveInputTarget && this.removeInputTarget.checked
    const src = this.picked || (removed ? null : this.savedImage)
    if (this.hasImageTarget) {
      if (src) this.imageTarget.setAttribute("src", src)
      this.imageTarget.hidden = !src
    }
    if (this.hasEmojiTarget) this.emojiTarget.hidden = Boolean(src)
  }

  // The same rounding as Prize.hours_text: a whole number or one decimal place, rounded half up.
  hoursText(coins) {
    const tenths = Math.round((coins * 10) / this.coinsPerHourValue)
    const value = tenths / 10
    return `${value} ${value === 1 ? "hour" : "hours"}`
  }
}
