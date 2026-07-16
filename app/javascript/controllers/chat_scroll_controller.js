import { Controller } from "@hotwired/stimulus"

// Mantém a área de mensagens do chat rolada até o final ao carregar a página.
export default class extends Controller {
  static targets = ["messages"]

  connect() {
    this.scrollToBottom()
  }

  scrollToBottom() {
    this.messagesTarget.scrollTop = this.messagesTarget.scrollHeight
  }
}
