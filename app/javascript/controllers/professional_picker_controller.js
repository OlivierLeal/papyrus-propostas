import { Controller } from "@hotwired/stimulus"

// Busca de profissional pra adicionar à Equipe (Tela de Precificação). Catálogo pequeno (~20-30
// ativos), filtro 100% client-side — os dados vêm prontos em `professionalsValue`.
//
// Escolha acontece no MOUSEDOWN, não no click (2026-09, relato do consultor: "seleciono a pessoa
// e não consigo adicionar"). No click, o blur do campo de busca (disparado já no mousedown) fechava
// e apagava a lista antes do click chegar — num clique humano normal (>150ms entre apertar e
// soltar) o botão sumia, ninguém ficava selecionado e o "Adicionar" falhava. `preventDefault` no
// mousedown mantém o foco no campo e elimina a corrida.
export default class extends Controller {
  static targets = ["search", "results", "hiddenId", "selected", "selectedName", "selectedMeta", "submit", "deliverable"]
  static values = { professionals: Array }

  connect() {
    this.activeIndex = -1
    this.matches = []
    this.clear()
  }

  search() {
    const query = this.normalize(this.searchTarget.value.trim())
    if (query.length === 0) {
      this.hideResults()
      return
    }

    this.matches = this.professionalsValue.filter((professional) => {
      return this.normalize(`${professional.name} ${professional.role} ${professional.specialties || ""}`).includes(query)
    }).slice(0, 8)
    this.activeIndex = this.matches.length > 0 ? 0 : -1
    this.renderResults()
  }

  // mousedown (não click) — ver comentário no topo.
  pick(event) {
    event.preventDefault()
    this.select(this.matches[Number(event.currentTarget.dataset.index)])
  }

  keydown(event) {
    // Enter aqui nunca pode submeter nada — o campo de busca fica dentro do form principal da
    // tela (#pricing-form), e o Enter "solto" dispararia o salvar do preço.
    if (event.key === "Enter") event.preventDefault()
    if (this.resultsTarget.classList.contains("hidden")) return

    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault()
      const step = event.key === "ArrowDown" ? 1 : -1
      this.activeIndex = (this.activeIndex + step + this.matches.length) % this.matches.length
      this.renderResults()
    } else if (event.key === "Enter") {
      if (this.activeIndex >= 0) this.select(this.matches[this.activeIndex])
    } else if (event.key === "Escape") {
      this.hideResults()
    }
  }

  select(professional) {
    if (!professional) return

    this.hiddenIdTarget.value = professional.id
    this.selectedNameTarget.textContent = professional.name
    this.selectedMetaTarget.textContent = [professional.role, professional.rate].filter(Boolean).join(" · ")
    this.selectedTarget.classList.remove("hidden")
    this.searchTarget.classList.add("hidden")
    this.hideResults()
    this.submitTarget.disabled = false
    if (this.hasDeliverableTarget) this.deliverableTarget.focus()
  }

  clear() {
    this.hiddenIdTarget.value = ""
    this.searchTarget.value = ""
    this.selectedTarget.classList.add("hidden")
    this.searchTarget.classList.remove("hidden")
    this.submitTarget.disabled = true
    this.hideResults()
  }

  // Botão "trocar" do selo da pessoa escolhida.
  reset() {
    this.clear()
    this.searchTarget.focus()
  }

  blur() {
    setTimeout(() => this.hideResults(), 100)
  }

  renderResults() {
    if (this.matches.length === 0) {
      this.resultsTarget.innerHTML = `<li class="px-3 py-3 text-sm text-base-content/50">Ninguém encontrado com esse termo.</li>`
      this.resultsTarget.classList.remove("hidden")
      return
    }

    this.resultsTarget.innerHTML = this.matches.map((professional, index) => `
      <li>
        <button type="button" data-index="${index}" data-action="mousedown->professional-picker#pick"
                class="w-full text-left px-3 py-2 flex items-center gap-3 ${index === this.activeIndex ? "bg-base-200" : "hover:bg-base-200/60"}">
          <span class="size-8 rounded-full bg-primary/10 text-primary text-xs font-semibold flex items-center justify-center shrink-0">${this.escape(this.initials(professional.name))}</span>
          <span class="min-w-0 flex-1">
            <span class="block text-sm text-base-content truncate">${this.escape(professional.name)}${professional.fixed ? ` <span class="badge badge-soft badge-info badge-xs ml-1">Fixo</span>` : ""}</span>
            <span class="block text-xs text-base-content/60 truncate">${this.escape(professional.role)}</span>
          </span>
          <span class="text-xs text-base-content/50 shrink-0">${this.escape(professional.rate || "")}</span>
        </button>
      </li>
    `).join("")
    this.resultsTarget.classList.remove("hidden")
  }

  hideResults() {
    this.resultsTarget.classList.add("hidden")
    this.resultsTarget.innerHTML = ""
  }

  initials(name) {
    return name.split(/\s+/).filter(Boolean).slice(0, 2).map((part) => part[0]).join("").toUpperCase()
  }

  normalize(text) {
    return text.toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "")
  }

  escape(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }
}
