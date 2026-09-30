import { Controller } from "@hotwired/stimulus"

// Recolhe/abre o painel lateral da proposta pra dar a largura toda ao chat. A escolha vai num cookie
// (vale pra todas as propostas): o servidor já desenha a tela recolhida, então o refresh por morph
// não faz o painel piscar aberto.
export default class extends Controller {
  collapse() {
    this.set(true)
  }

  expand() {
    this.set(false)
  }

  set(collapsed) {
    this.element.dataset.collapsed = String(collapsed)
    document.cookie = `side_panel_collapsed=${collapsed ? 1 : 0}; path=/; max-age=31536000; SameSite=Lax`
  }
}
