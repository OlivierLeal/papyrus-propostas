import { Controller } from "@hotwired/stimulus"

// Mantém a área de mensagens do chat rolada até o final ao carregar a página e quando uma
// mensagem nova chega via Turbo Stream (broadcast_append_to), sem precisar de F5. Só força o
// scroll se a pessoa já estava perto do final — se ela rolou pra cima pra ler o histórico, uma
// mensagem nova não deve puxá-la de volta à força.
const NEAR_BOTTOM_THRESHOLD_PX = 80

export default class extends Controller {
  static targets = ["messages"]

  connect() {
    this.isNearBottom = true
    this.trackPosition = this.trackPosition.bind(this)
    this.messagesTarget.addEventListener("scroll", this.trackPosition)

    this.scrollToBottom()
    this.observer = new MutationObserver(() => this.maybeScrollToBottom())
    this.observer.observe(this.messagesTarget, { childList: true, characterData: true, subtree: true })
  }

  disconnect() {
    this.observer?.disconnect()
    this.messagesTarget.removeEventListener("scroll", this.trackPosition)
  }

  trackPosition() {
    const { scrollTop, scrollHeight, clientHeight } = this.messagesTarget
    this.isNearBottom = scrollHeight - (scrollTop + clientHeight) < NEAR_BOTTOM_THRESHOLD_PX
  }

  maybeScrollToBottom() {
    if (this.isNearBottom) this.scrollToBottom()
  }

  scrollToBottom() {
    this.messagesTarget.scrollTop = this.messagesTarget.scrollHeight
  }
}
