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
    this.placeholder = this.inputTarget.placeholder

    // "A IA está respondendo" = o indicador de digitando está na lista de mensagens (ele chega por
    // broadcast pra todas as abas quando a IA começa e é removido quando ela termina). Enquanto
    // isso, dá pra escrever mas não enviar — o servidor recusaria de qualquer jeito (ver
    // AiResponding), e o texto digitado nunca se perde.
    this.messages = document.getElementById("messages")
    if (this.messages) {
      this.observer = new MutationObserver(() => this.syncBusy())
      this.observer.observe(this.messages, { childList: true })
    }
    this.syncBusy()
  }

  disconnect() {
    this.observer?.disconnect()
  }

  syncBusy() {
    this.busy = Boolean(document.getElementById("typing_indicator"))
    this.submitTarget.disabled = this.busy
    this.submitTarget.value = this.busy ? "Aguarde..." : "Enviar"
    this.inputTarget.placeholder = this.busy
      ? "A IA está respondendo… pode ir escrevendo, você envia quando ela terminar."
      : this.placeholder
  }

  // Barra de rolagem só quando passa do limite (max-h do campo); antes disso ela aparecia à toa
  // numa linha só, porque o scrollHeight arredonda pra cima do height calculado.
  resize() {
    const input = this.inputTarget
    input.style.height = "auto"
    input.style.height = `${input.scrollHeight}px`
    input.style.overflowY = input.scrollHeight > input.clientHeight + 2 ? "auto" : "hidden"
  }

  submitOnEnter(event) {
    if (event.key !== "Enter" || event.shiftKey) return

    event.preventDefault()
    if (this.busy) return
    this.element.requestSubmit()
  }

  lock() {
    this.inputTarget.disabled = true
    this.submitTarget.disabled = true
    this.submitTarget.value = "Enviando..."
  }

  unlock() {
    this.inputTarget.disabled = false
    this.syncBusy()
  }
}
