import { Controller } from "@hotwired/stimulus"

// Abas do painel lateral da proposta. O servidor escolhe a aba padrão (a que pede atenção); a que o
// consultor escolher fica guardada na sessão do navegador e volta a valer depois do refresh por
// morph (turbo-refresh-method=morph), que redesenha os painéis com o `hidden` do servidor.
export default class extends Controller {
  static targets = ["tab", "panel"]
  static values = { default: String, key: String }

  connect() {
    this.reapply = () => this.show(this.stored() || this.defaultValue)
    document.addEventListener("turbo:morph", this.reapply)
    this.reapply()
  }

  disconnect() {
    document.removeEventListener("turbo:morph", this.reapply)
  }

  select(event) {
    const name = event.currentTarget.dataset.tab
    try { sessionStorage.setItem(this.storageKey, name) } catch (_) { /* sem storage: vale a padrão */ }
    this.show(name)
  }

  show(name) {
    if (!this.tabTargets.some((tab) => tab.dataset.tab === name)) name = this.defaultValue
    this.tabTargets.forEach((tab) => tab.setAttribute("aria-selected", String(tab.dataset.tab === name)))
    this.panelTargets.forEach((panel) => { panel.hidden = panel.dataset.tab !== name })
  }

  stored() {
    try { return sessionStorage.getItem(this.storageKey) } catch (_) { return null }
  }

  get storageKey() {
    return `tabs:${this.keyValue}`
  }
}
