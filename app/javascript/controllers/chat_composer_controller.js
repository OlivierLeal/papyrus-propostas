import { Controller } from "@hotwired/stimulus"

// Comportamento do campo de mensagem do chat: cresce conforme digita (até um limite, depois
// rola dentro do próprio campo), Enter envia (Shift+Enter quebra linha), e trava o formulário
// enquanto espera a resposta do servidor — evita clique duplo e dá feedback de "enviando". O
// composer inteiro é substituído por uma cópia limpa quando a resposta chega (ver
// messages#create.turbo_stream.erb), então "unlock" só importa mesmo se a requisição falhar.
export default class extends Controller {
  static targets = ["input", "submit"]

  connect() {
    this.resize()
    this.inputTarget.focus()
  }

  resize() {
    this.inputTarget.style.height = "auto"
    this.inputTarget.style.height = `${this.inputTarget.scrollHeight}px`
  }

  submitOnEnter(event) {
    if (event.key !== "Enter" || event.shiftKey) return

    event.preventDefault()
    this.element.requestSubmit()
  }

  lock() {
    this.inputTarget.disabled = true
    this.submitTarget.disabled = true
    this.submitTarget.value = "Enviando..."
  }

  unlock() {
    this.inputTarget.disabled = false
    this.submitTarget.disabled = false
    this.submitTarget.value = "Enviar"
  }
}
