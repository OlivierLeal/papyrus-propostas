import { Controller } from "@hotwired/stimulus"

// Mantém a área de mensagens do chat rolada até o final ao carregar a página e
// quando a resposta da IA chega via Turbo Stream (broadcast_append_to), sem precisar de F5.
export default class extends Controller {
  static targets = ["messages"]

  connect() {
    this.scrollToBottom()
    this.observer = new MutationObserver(() => this.scrollToBottom())
    this.observer.observe(this.messagesTarget, { childList: true, characterData: true, subtree: true })
  }

  disconnect() {
    this.observer?.disconnect()
  }

  scrollToBottom() {
    this.messagesTarget.scrollTop = this.messagesTarget.scrollHeight
  }
}
