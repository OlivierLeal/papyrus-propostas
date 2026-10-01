import { Controller } from "@hotwired/stimulus"

// Botão de olho ao lado do campo de senha: alterna entre mostrar e esconder o
// que foi digitado, sem tirar o foco do campo.
export default class extends Controller {
  static targets = ["input", "showIcon", "hideIcon", "button"]

  toggle(event) {
    event.preventDefault()
    const visible = this.inputTarget.type === "password"
    this.inputTarget.type = visible ? "text" : "password"
    this.showIconTarget.classList.toggle("hidden", visible)
    this.hideIconTarget.classList.toggle("hidden", !visible)
    this.buttonTarget.setAttribute("aria-label", visible ? "Esconder senha" : "Mostrar senha")
    this.buttonTarget.setAttribute("aria-pressed", visible)
    this.inputTarget.focus()
  }
}
