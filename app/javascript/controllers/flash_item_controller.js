import { Controller } from "@hotwired/stimulus"

// Notificação de flash estilo Ant Design: some sozinha quando a barra de
// progresso termina, e pausa a contagem enquanto o mouse está em cima.
export default class extends Controller {
  static targets = ["progress"]

  connect() {
    this.progressTarget.addEventListener("animationend", () => this.dismiss())
  }

  pause() {
    this.progressTarget.style.animationPlayState = "paused"
  }

  resume() {
    this.progressTarget.style.animationPlayState = "running"
  }

  dismiss() {
    this.element.classList.add("flash-leave")
    this.element.addEventListener("transitionend", () => this.element.remove(), { once: true })
  }
}
