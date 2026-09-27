import { Controller } from "@hotwired/stimulus"

// Prévia ao vivo da Tela de Precificação (2026-09-27, pedido do consultor: mudar a hora-homem e
// ver o valor mudar na hora, "pra pessoa ir verificando se faz sentido"). Refaz no navegador a
// MESMA conta do Ruby — ProposalProfessional#expected_subtotal e ProjectPricing#logistics_breakdown/
// #total_value — a cada tecla. É só prévia: o valor que vale é o do servidor ao salvar
// ("Salvar e recalcular"), e o selo `dirty` avisa que há alteração não gravada.
// Se mudar a fórmula em Ruby, mude aqui também.
export default class extends Controller {
  static targets = [
    "line", "teamHours", "teamDays", "teamTotal", "people",
    "lodging", "meals", "rental", "fuel", "logistics",
    "summaryTotal", "summaryTeam", "summaryLogistics", "installment", "dirty"
  ]
  static values = { externalTotal: Number }

  update() {
    const bdi = this.field("bdi")
    const tax = this.field("tax_multiplier")

    let hours = 0
    let days = 0
    let team = 0
    let peopleInField = 0
    this.lineTargets.forEach((row) => {
      const lineHours = this.number(row.querySelector("input[name$='[man_hours]']"))
      const lineDays = this.number(row.querySelector("input[name$='[field_days]']"))
      const subtotal = this.round((lineHours * Number(row.dataset.rateHour) + lineDays * Number(row.dataset.rateDay)) * bdi * tax)
      hours += lineHours
      days += lineDays
      team += subtotal
      if (lineDays > 0) peopleInField += 1
      const cell = row.querySelector("[data-role='subtotal']")
      if (cell) cell.textContent = this.brl(subtotal)
    })

    // ProjectPricing#field_professionals_count: quem tem diárias, mínimo 1.
    const people = Math.max(peopleInField, 1)
    const fieldDays = this.field("logistics_days")
    const lodging = this.field("lodging_per_person_per_night") * people * fieldDays
    const meals = this.field("meal_per_person_per_day") * people * fieldDays
    const rental = this.field("rental_per_day") * this.field("vehicles_count") * fieldDays
    const fuel = this.field("fuel_total")
    const logistics = lodging + meals + rental + fuel
    const total = this.round(team + logistics + this.externalTotalValue)

    this.set(this.teamHoursTargets, `${this.decimal(hours)} HH`)
    this.set(this.teamDaysTargets, this.decimal(days))
    this.set(this.teamTotalTargets, this.brl(team))
    this.set(this.peopleTargets, `${people} ${people === 1 ? "pessoa" : "pessoas"}`)
    this.set(this.lodgingTargets, this.brl(lodging))
    this.set(this.mealsTargets, this.brl(meals))
    this.set(this.rentalTargets, this.brl(rental))
    this.set(this.fuelTargets, this.brl(fuel))
    this.set(this.logisticsTargets, this.brl(logistics))
    this.set(this.summaryTeamTargets, this.brl(team))
    this.set(this.summaryLogisticsTargets, this.brl(logistics))
    this.set(this.summaryTotalTargets, this.brl(total))
    this.updateInstallments(total)
    this.dirtyTargets.forEach((element) => { element.hidden = false })

    // O desembolso editável (payment_schedule_controller) recalcula as parcelas com o novo total.
    this.dispatch("total", { detail: { total } })
  }

  // Resumo lateral: % salvo × total da prévia; a última parcela absorve o arredondamento
  // (ProjectPricing#payment_schedule_amounts).
  updateInstallments(total) {
    const percentages = this.installmentTargets.map((element) => Number(element.dataset.percentage) || 0)
    const amounts = percentages.map((p) => this.round(total * p / 100))
    const sum = percentages.reduce((a, b) => a + b, 0)
    if (amounts.length > 0 && Math.abs(sum - 100) < 0.0001) {
      amounts[amounts.length - 1] = this.round(total - amounts.slice(0, -1).reduce((a, b) => a + b, 0))
    }
    this.installmentTargets.forEach((element, i) => { element.textContent = this.brl(amounts[i]) })
  }

  field(name) {
    return this.number(this.element.querySelector(`[name='project_pricing[${name}]']`))
  }

  number(input) {
    if (!input) return 0
    return parseFloat(String(input.value).replace(",", ".")) || 0
  }

  round(value) {
    return Math.round(value * 100) / 100
  }

  set(targets, text) {
    targets.forEach((element) => { element.textContent = text })
  }

  brl(value) {
    return value.toLocaleString("pt-BR", { style: "currency", currency: "BRL" })
  }

  decimal(value) {
    return value.toLocaleString("pt-BR", { minimumFractionDigits: 1, maximumFractionDigits: 1 })
  }
}
