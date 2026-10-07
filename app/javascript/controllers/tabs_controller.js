import { Controller } from "@hotwired/stimulus"

// Abas do painel lateral da proposta e da Tela de Precificação. O servidor escolhe a aba padrão (a
// que pede atenção); a que o consultor escolher fica guardada na sessão do navegador e volta a valer
// depois do refresh por morph (turbo-refresh-method=morph), que redesenha os painéis com o `hidden`
// do servidor, e depois do redirect de "Salvar e recalcular".
//
// Âncora na URL (ex.: #campo-12, depois de "+ Campo") vence a aba guardada: mostra a aba que contém
// o elemento e abre os <details> em volta dele. E um campo obrigatório inválido numa aba escondida
// faria o navegador recusar o envio sem mostrar nada — o evento `invalid` mostra a aba dele.
export default class extends Controller {
  static targets = ["tab", "panel"]
  static values = { default: String, key: String }

  connect() {
    const hashTab = this.fromHash()
    if (hashTab) this.store(hashTab)
    this.reapply = () => this.show(this.stored() || this.defaultValue)
    this.revealInvalid = (event) => this.reveal(event.target)
    // Link interno (ex.: "+ logística" da aba Equipe → #item-12) só muda a âncora: abre a aba dela.
    this.followHash = () => {
      const tab = this.fromHash()
      if (!tab) return
      this.store(tab)
      this.hashTarget()?.querySelectorAll("details").forEach((details) => { details.open = true })
      this.scrollToHash()
    }
    window.addEventListener("hashchange", this.followHash)
    document.addEventListener("turbo:morph", this.reapply)
    this.element.addEventListener("invalid", this.revealInvalid, true)
    this.reapply()
    this.scrollToHash()
  }

  disconnect() {
    window.removeEventListener("hashchange", this.followHash)
    document.removeEventListener("turbo:morph", this.reapply)
    this.element.removeEventListener("invalid", this.revealInvalid, true)
  }

  select(event) {
    const name = event.currentTarget.dataset.tab
    this.store(name)
    this.show(name)
  }

  store(name) {
    try { sessionStorage.setItem(this.storageKey, name) } catch (_) { /* sem storage: vale a padrão */ }
  }

  show(name) {
    if (!this.tabTargets.some((tab) => tab.dataset.tab === name)) name = this.defaultValue
    this.tabTargets.forEach((tab) => tab.setAttribute("aria-selected", String(tab.dataset.tab === name)))
    this.panelTargets.forEach((panel) => { panel.hidden = panel.dataset.tab !== name })
  }

  reveal(element) {
    const panel = this.panelTargets.find((candidate) => candidate.contains(element))
    if (panel && panel.hidden) this.show(panel.dataset.tab)
    for (let node = element; node && node !== this.element; node = node.parentElement) {
      if (node.tagName === "DETAILS") node.open = true
    }
  }

  fromHash() {
    const target = this.hashTarget()
    const panel = target && this.panelTargets.find((candidate) => candidate.contains(target))
    return panel?.dataset.tab
  }

  scrollToHash() {
    const target = this.hashTarget()
    if (!target) return
    this.reveal(target)
    requestAnimationFrame(() => target.scrollIntoView({ block: "start" }))
  }

  hashTarget() {
    const id = decodeURIComponent(window.location.hash.slice(1))
    if (!id) return null
    const target = document.getElementById(id)
    return target && this.element.contains(target) ? target : null
  }

  stored() {
    try { return sessionStorage.getItem(this.storageKey) } catch (_) { return null }
  }

  get storageKey() {
    return `tabs:${this.keyValue}`
  }
}
