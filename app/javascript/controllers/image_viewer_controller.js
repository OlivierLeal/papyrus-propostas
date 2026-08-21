import { Controller } from "@hotwired/stimulus"

// Abre uma imagem (hoje o mapa da área de estudo) ampliada num <dialog> nativo — o polígono do
// KMZ fica ilegível na miniatura da barra lateral, que é estreita por natureza.
//
// Usa <dialog> em vez de um overlay próprio para herdar de graça o que o navegador já faz bem:
// fechar no ESC, prender o foco dentro do modal e empilhar acima de qualquer outro conteúdo.
export default class extends Controller {
  static targets = ["dialog"]

  open() {
    this.dialogTarget.showModal()
  }

  close() {
    this.dialogTarget.close()
  }

  // Clicar fora da imagem fecha. O <dialog> recebe o clique do backdrop como se fosse dele
  // mesmo, então comparar o alvo com o próprio elemento distingue backdrop de conteúdo.
  closeOnBackdrop(event) {
    if (event.target === this.dialogTarget) this.close()
  }
}
