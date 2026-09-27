import { Controller } from "@hotwired/stimulus"

// Desembolso editável na Tela de Precificação: adicionar/remover parcela e ver o valor de cada
// uma (e a soma dos %) na hora, antes de salvar. O cálculo "oficial" continua em Ruby
// (ProjectPricing#payment_schedule_amounts) — aqui é só prévia; salvar é que grava.
export default class extends Controller {
  static targets = ["body", "template", "row", "percentage", "amount", "sum", "warning"]
  static values = { total: Number }

  connect() {
    this.recalculate()
  }

  add() {
    const index = Date.now()
    this.bodyTarget.insertAdjacentHTML("beforeend", this.templateTarget.innerHTML.replaceAll("NEW_INDEX", index))
    this.recalculate()
    this.rowTargets.at(-1)?.querySelector("input[type=text]")?.focus()
  }

  // Remover = esvaziar o marco e esconder a linha: o servidor descarta parcela sem marco
  // (ProjectPricing#payment_schedule_items=), sem precisar de rota própria.
  remove(event) {
    const row = event.target.closest("[data-payment-schedule-target='row']")
    row.querySelector("input[name$='[label]']").value = ""
    row.hidden = true
    row.removeAttribute("data-payment-schedule-target")
    row.querySelector("[data-payment-schedule-target='percentage']")?.removeAttribute("data-payment-schedule-target")
    row.querySelector("[data-payment-schedule-target='amount']")?.removeAttribute("data-payment-schedule-target")
    this.recalculate()
  }

  recalculate() {
    const percentages = this.percentageTargets.map((input) => parseFloat(input.value.replace(",", ".")) || 0)
    const sum = percentages.reduce((a, b) => a + b, 0)
    const amounts = percentages.map((p) => Math.round(this.totalValue * p) / 100)
    if (Math.abs(sum - 100) < 0.0001 && amounts.length > 0) {
      amounts[amounts.length - 1] = Math.round((this.totalValue - amounts.slice(0, -1).reduce((a, b) => a + b, 0)) * 100) / 100
    }

    this.amountTargets.forEach((cell, i) => { cell.textContent = this.brl(amounts[i]) })
    this.sumTarget.textContent = `${sum.toLocaleString("pt-BR", { maximumFractionDigits: 2 })}%`
    const ok = Math.abs(sum - 100) < 0.0001
    this.sumTarget.classList.toggle("text-error", !ok)
    this.warningTarget.hidden = ok
  }

  brl(value) {
    return value.toLocaleString("pt-BR", { style: "currency", currency: "BRL" })
  }
}
