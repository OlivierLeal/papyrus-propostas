import { Controller } from "@hotwired/stimulus"

// Mostra os nomes dos arquivos selecionados no input de anexo do chat.
export default class extends Controller {
  static targets = ["input", "filenames"]

  update() {
    const files = Array.from(this.inputTarget.files)

    if (files.length === 0) {
      this.filenamesTarget.textContent = ""
      this.filenamesTarget.classList.add("hidden")
      return
    }

    this.filenamesTarget.textContent = `Anexado: ${files.map((file) => file.name).join(", ")}`
    this.filenamesTarget.classList.remove("hidden")
  }
}
