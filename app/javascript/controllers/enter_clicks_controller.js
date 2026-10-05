import { Controller } from "@hotwired/stimulus"

// Enter num campo aperta o botão certo (2026-10): no #pricing-form o Enter faria o envio padrão
// ("Salvar e recalcular"), não a ação ao lado do campo — ex.: criar item pela aba Equipe.
export default class extends Controller {
  static targets = ["button"]

  press(event) {
    if (event.key !== "Enter") return
    event.preventDefault()
    this.buttonTarget.click()
  }
}
