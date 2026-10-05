import { Controller } from "@hotwired/stimulus"

// "Adicionar à equipe" com item novo (2026-10): escolher "+ Novo item…" no seletor de item mostra o
// campo do nome (obrigatório só nesse caso); o servidor cria o item junto com a linha
// (ProposalProfessionalsController#create).
export default class extends Controller {
  static targets = ["select", "name"]

  connect() {
    this.toggle()
  }

  toggle() {
    const isNew = this.selectTarget.value === "new"
    this.nameTarget.hidden = !isNew
    const input = this.nameTarget.querySelector("input")
    input.required = isNew
    if (isNew) input.focus()
  }
}
