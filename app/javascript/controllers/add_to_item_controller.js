import { Controller } from "@hotwired/stimulus"

// "+ Pessoa" no cabeçalho de cada item da aba Equipe (2026-10, proposta 69: o "Adicionar à equipe"
// fica no fim da página e começa no 1º item — quem não trocava o item mandava a pessoa "lá pra
// cima"). Escolhe o item no formulário de adicionar, rola até ele e põe o cursor na busca.
export default class extends Controller {
  pick(event) {
    event.preventDefault()
    const form = document.getElementById("add-member-panel")
    const select = form?.querySelector("select[name='proposal_professional[pricing_item_id]']")
    if (!select) return

    select.value = event.params.item
    select.dispatchEvent(new Event("change", { bubbles: true }))
    form.querySelector("[data-role='add-to-item-label']")?.replaceChildren(document.createTextNode(`em ${event.params.name}`))
    form.scrollIntoView({ block: "center", behavior: "smooth" })
    form.querySelector("[data-professional-picker-target='search']")?.focus({ preventScroll: true })
  }
}
