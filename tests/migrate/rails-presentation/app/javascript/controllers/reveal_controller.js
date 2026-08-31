export default class extends Controller {
  static targets = ["details"]
  static values = { open: Boolean }

  toggle() {
    this.openValue = !this.openValue
    this.detailsTarget.classList.toggle("hidden", !this.openValue)
  }
}
