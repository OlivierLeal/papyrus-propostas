import { Controller } from "@hotwired/stimulus"

// Arrastar um arquivo pra cima do painel da conversa e soltar: ele entra na seleção do composer
// (o mesmo input documents[] do clipe), pronto pra ir junto com a próxima mensagem. Reaproveita
// o truque de DataTransfer do file_list_controller pra "editar" input.files (append, nunca
// replace) e dispara "change" pra o file_list_controller redesenhar os chips.
//
// O controller fica no painel (não no composer) porque o composer é substituído por uma cópia
// limpa a cada mensagem enviada (messages#create.turbo_stream.erb); o Stimulus reconecta o
// target "input" sozinho quando o composer novo entra no DOM.
export default class extends Controller {
  static targets = ["input", "overlay"]

  over(event) {
    if (!this.draggingFiles(event)) return

    event.preventDefault()
    if (this.hasOverlayTarget) this.overlayTarget.hidden = false
  }

  leave(event) {
    // dragleave também dispara ao cruzar elementos filhos — só esconde quando o ponteiro sai do
    // painel de verdade.
    if (event.relatedTarget && this.element.contains(event.relatedTarget)) return
    if (this.hasOverlayTarget) this.overlayTarget.hidden = true
  }

  drop(event) {
    if (!this.draggingFiles(event)) return

    event.preventDefault()
    if (this.hasOverlayTarget) this.overlayTarget.hidden = true
    if (!this.hasInputTarget) return

    const dropped = Array.from(event.dataTransfer.files)
    if (dropped.length === 0) return

    const transfer = new DataTransfer()
    Array.from(this.inputTarget.files).forEach((file) => transfer.items.add(file))
    dropped.forEach((file) => transfer.items.add(file))

    this.inputTarget.files = transfer.files
    this.inputTarget.dispatchEvent(new Event("change", { bubbles: true }))
  }

  draggingFiles(event) {
    return Array.from(event.dataTransfer?.types || []).includes("Files")
  }
}
