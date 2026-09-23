import { Controller } from "@hotwired/stimulus"

// Campo de busca pra escolher o profissional na hora de "Adicionar linha" na Equipe (Tela de
// Precificação) — pedido do consultor (2026-09): o <select> simples virou uma lista longa demais
// de rolar; ele queria algo no estilo "buscar endereço" (campo de texto, filtra a lista, clica
// pra escolher). O catálogo é pequeno (~20-30 profissionais ativos), então o filtro é 100%
// client-side, sem round-trip nenhum ao servidor — os dados já vêm prontos no atributo
// `professionalsValue` (id/nome/cargo/especialidades, o mesmo que já era passado pro <select>
// antigo). O <select> real continua existindo por baixo (hidden), então o resto do formulário
// ("Adicionar linha") não muda nada — só a forma de escolher quem entra nele.
export default class extends Controller {
  static targets = ["search", "results", "hiddenId", "selectedBadge"]
  static values = { professionals: Array }

  connect() {
    this.selected = null
    this.hideResults()
  }

  // "input" no campo de busca — filtra por nome, cargo ou especialidades (case-insensitive; sem
  // normalizar acento de propósito, o catálogo já usa nomes/cargos bem conhecidos pelo
  // consultor, não vale a complexidade extra de remover acento só pra isso).
  search() {
    const query = this.searchTarget.value.trim().toLowerCase()
    this.selected = null
    this.hiddenIdTarget.value = ""
    this.selectedBadgeTarget.textContent = ""

    if (query.length === 0) {
      this.hideResults()
      return
    }

    const matches = this.professionalsValue.filter((professional) => {
      const haystack = `${professional.name} ${professional.role} ${professional.specialties || ""}`.toLowerCase()
      return haystack.includes(query)
    })

    this.renderResults(matches)
  }

  // Clique num resultado da lista — fixa a escolha no <select> hidden (que é o que o form
  // realmente envia) e mostra um selo com o nome escolhido, pra ficar claro que já selecionou.
  choose(event) {
    const id = event.params.id
    const professional = this.professionalsValue.find((p) => String(p.id) === String(id))
    if (!professional) return

    this.selected = professional
    this.hiddenIdTarget.value = professional.id
    this.searchTarget.value = professional.name
    this.selectedBadgeTarget.textContent = `${professional.role} — ${professional.specialties || "sem especialidade cadastrada"}`
    this.hideResults()
  }

  // Enter no campo de busca escolhe o 1º resultado filtrado, pra não precisar tirar a mão do
  // teclado pra clicar quando já sabe o que quer digitar.
  submitOnEnter(event) {
    if (event.key !== "Enter") return
    const first = this.resultsTarget.querySelector("[data-action~='click->professional-picker#choose']")
    if (!first) return

    event.preventDefault()
    first.click()
  }

  renderResults(matches) {
    if (matches.length === 0) {
      this.resultsTarget.innerHTML = "<li class=\"px-3 py-2 text-sm text-base-content/50\">Nenhum profissional encontrado.</li>"
      this.showResults()
      return
    }

    this.resultsTarget.innerHTML = matches.slice(0, 8).map((professional) => `
      <li>
        <button type="button" class="w-full text-left px-3 py-2 text-sm hover:bg-base-200 flex flex-col"
                data-action="click->professional-picker#choose" data-professional-picker-id-param="${professional.id}">
          <span class="text-base-content">${professional.name}</span>
          <span class="text-base-content/60 text-xs">${professional.role}</span>
        </button>
      </li>
    `).join("")
    this.showResults()
  }

  showResults() {
    this.resultsTarget.classList.remove("hidden")
  }

  hideResults() {
    this.resultsTarget.classList.add("hidden")
    this.resultsTarget.innerHTML = ""
  }

  // Clicar fora fecha a lista sem desfazer a escolha já feita (mesmo padrão de "buscar
  // endereço" — a lista só existe enquanto está digitando/olhando as opções).
  blur() {
    setTimeout(() => this.hideResults(), 150)
  }
}
