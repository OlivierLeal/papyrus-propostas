import { Controller } from "@hotwired/stimulus"

// Mostra os arquivos selecionados num <input type="file" multiple> como chips removíveis — o
// input nativo não deixa tirar um arquivo específico da seleção, só limpar tudo ou reabrir o
// diálogo (que troca a seleção inteira). DataTransfer reconstrói a FileList sem o item removido
// e reatribui a input.files, que é o único jeito de "editar" a seleção de um <input type="file">.
export default class extends Controller {
  static targets = ["input", "list"]

  update() {
    this.render()
  }

  remove(event) {
    const index = Number(event.params.index)
    const transfer = new DataTransfer()

    Array.from(this.inputTarget.files).forEach((file, i) => {
      if (i !== index) transfer.items.add(file)
    })

    this.inputTarget.files = transfer.files
    this.render()
  }

  render() {
    const files = Array.from(this.inputTarget.files)
    this.listTarget.replaceChildren()
    this.listTarget.classList.toggle("hidden", files.length === 0)

    files.forEach((file, index) => {
      const chip = document.createElement("span")
      chip.className = "badge badge-soft gap-1 max-w-full"

      const name = document.createElement("span")
      name.className = "truncate"
      name.textContent = file.name
      chip.appendChild(name)

      const button = document.createElement("button")
      button.type = "button"
      button.className = "shrink-0"
      button.setAttribute("aria-label", `Remover ${file.name}`)
      button.dataset.action = "file-list#remove"
      button.dataset.fileListIndexParam = index
      button.textContent = "×"
      chip.appendChild(button)

      this.listTarget.appendChild(chip)
    })
  }
}
