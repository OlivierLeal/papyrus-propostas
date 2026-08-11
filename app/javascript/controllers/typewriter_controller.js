import { Controller } from "@hotwired/stimulus"

// Revela o HTML já renderizado (markdown->HTML feito no servidor) progressivamente, como se
// estivesse sendo digitado. Anima nó de texto por nó de texto (não o HTML bruto), então tags
// aninhadas (negrito, listas, links) nunca quebram no meio — só o conteúdo de cada nó de texto
// vai enchendo aos poucos, na ordem em que aparecem no documento.
export default class extends Controller {
  static values = { intervalMs: { type: Number, default: 15 } }

  connect() {
    const walker = document.createTreeWalker(this.element, NodeFilter.SHOW_TEXT)
    this.nodes = []
    let node
    while ((node = walker.nextNode())) {
      this.nodes.push({ node, full: node.textContent, revealed: 0 })
      node.textContent = ""
    }

    const totalLength = this.nodes.reduce((sum, entry) => sum + entry.full.length, 0)
    this.charsPerTick = Math.max(1, Math.ceil(totalLength / 120))

    this.timer = setInterval(() => this.reveal(), this.intervalMsValue)
  }

  disconnect() {
    clearInterval(this.timer)
  }

  reveal() {
    let remaining = this.charsPerTick
    let pending = false

    for (const entry of this.nodes) {
      if (entry.revealed >= entry.full.length) continue

      pending = true
      if (remaining <= 0) break

      const take = Math.min(remaining, entry.full.length - entry.revealed)
      entry.revealed += take
      entry.node.textContent = entry.full.slice(0, entry.revealed)
      remaining -= take
    }

    if (!pending) clearInterval(this.timer)
  }
}
