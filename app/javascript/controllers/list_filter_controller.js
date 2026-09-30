import { Controller } from "@hotwired/stimulus"

// Filtra uma lista pelo texto digitado (ex.: os tipos de estudo na janela "Editar estudos"),
// ignorando acento e caixa.
export default class extends Controller {
  static targets = ["item"]

  filter(event) {
    const query = this.normalize(event.target.value)
    this.itemTargets.forEach((item) => { item.hidden = !this.normalize(item.textContent).includes(query) })
  }

  normalize(text) {
    return text.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().trim()
  }
}
