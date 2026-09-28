import { Controller } from "@hotwired/stimulus"

// Prévia ao vivo da Tela de Precificação (2026-09-27, pedido do consultor: mudar a hora-homem e
// ver o valor mudar na hora, "pra pessoa ir verificando se faz sentido"). Refaz no navegador a
// MESMA conta do Ruby a cada tecla — ProposalProfessional#expected_subtotal, FieldCampaign#cost,
// PricingItem#total e ProjectPricing#recalculate! (2026-09-28: preço por item, logística por
// campo, tudo × BDI × impostos). É só prévia: o valor que vale é o do servidor ao salvar
// ("Salvar e recalcular"), e o selo `dirty` avisa que há alteração não gravada.
// Se mudar a fórmula em Ruby, mude aqui também.
export default class extends Controller {
  static targets = [
    "line", "teamHours", "teamDays", "teamTotal", "item", "campaign", "itemCost", "logistics",
    "summaryTotal", "summaryTeam", "summaryLogistics", "summaryItemCosts", "installment", "dirty"
  ]
  static values = { externalTotal: Number }

  update() {
    const multiplier = this.field("bdi") * this.field("tax_multiplier")
    const perItem = {}
    const bucket = (id) => (perItem[id] ||= { team: 0, campaigns: 0, costs: 0 })

    let hours = 0
    let days = 0
    let team = 0
    this.lineTargets.forEach((row) => {
      const lineHours = this.number(row.querySelector("input[name$='[man_hours]']"))
      const lineDays = this.number(row.querySelector("input[name$='[field_days]']"))
      const subtotal = this.round((lineHours * Number(row.dataset.rateHour) + lineDays * Number(row.dataset.rateDay)) * multiplier)
      hours += lineHours
      days += lineDays
      team += subtotal
      const itemSelect = row.querySelector("[data-role='line-item']")
      if (itemSelect) bucket(itemSelect.value).team += subtotal
      const cell = row.querySelector("[data-role='subtotal']")
      if (cell) cell.textContent = this.brl(subtotal)
    })

    let logistics = 0
    this.campaignTargets.forEach((row) => {
      const total = this.round(this.campaignCost(row) * multiplier)
      bucket(row.dataset.itemId).campaigns += total
      const cell = row.querySelector("[data-role='campaign-total']")
      if (cell) cell.textContent = this.brl(total)
    })

    let itemCosts = 0
    this.itemCostTargets.forEach((row) => {
      const cost = this.inner(row, "quantity") * this.inner(row, "unit_value") * multiplier
      bucket(row.dataset.itemId).costs += cost
      const cell = row.querySelector("[data-role='cost-total']")
      if (cell) cell.textContent = this.brl(this.round(cost))
    })

    // PricingItem#campaigns_total/#costs_total arredondam por item.
    this.itemTargets.forEach((card) => {
      const values = bucket(card.dataset.itemId)
      values.campaigns = this.round(values.campaigns)
      values.costs = this.round(values.costs)
      this.setRole(card, "item-team", this.brl(values.team))
      this.setRole(card, "item-campaigns", this.brl(values.campaigns))
      this.setRole(card, "item-costs", this.brl(values.costs))
      this.setRole(card, "item-total", this.brl(values.team + values.campaigns + values.costs))
    })
    Object.values(perItem).forEach((values) => {
      logistics += this.round(values.campaigns)
      itemCosts += this.round(values.costs)
    })

    const total = this.round(team + logistics + itemCosts + this.externalTotalValue)

    this.set(this.teamHoursTargets, `${this.decimal(hours)} HH`)
    this.set(this.teamDaysTargets, this.decimal(days))
    this.set(this.teamTotalTargets, this.brl(team))
    this.set(this.logisticsTargets, this.brl(logistics))
    this.set(this.summaryTeamTargets, this.brl(team))
    this.set(this.summaryLogisticsTargets, this.brl(logistics))
    this.set(this.summaryItemCostsTargets, this.brl(itemCosts))
    this.set(this.summaryTotalTargets, this.brl(total))
    this.updateInstallments(total)
    this.dirtyTargets.forEach((element) => { element.hidden = false })

    // O desembolso editável (payment_schedule_controller) recalcula as parcelas com o novo total.
    this.dispatch("total", { detail: { total } })
  }

  // FieldCampaign#breakdown — custo DIRETO do campo, antes do BDI × impostos.
  campaignCost(row) {
    const people = this.inner(row, "people")
    const days = this.inner(row, "days")
    const tripDays = days + this.inner(row, "travel_days")
    const vehicles = this.inner(row, "vehicles")
    const typeSelect = row.querySelector("[data-field='vehicle_type']")
    const rental = typeSelect && typeSelect.value === "4x4" ? this.field("rental_4x4_per_day") : this.field("rental_per_day")
    const consumption = this.field("vehicle_consumption_km_per_liter") || 1
    const km = this.field("distance_km") * 2 + this.field("daily_km") * days

    return vehicles * tripDays * rental +
      km * vehicles / consumption * this.field("fuel_price_per_liter") +
      people * tripDays * this.field("meal_per_person_per_day") +
      people * Math.max(tripDays - 1, 0) * this.field("lodging_per_person_per_night") +
      this.inner(row, "tolls") * this.field("toll_price") +
      this.inner(row, "washes") * this.field("wash_price") +
      this.inner(row, "uber_trips") * this.field("uber_price") +
      this.inner(row, "mateiro_days") * this.field("mateiro_per_day") +
      this.inner(row, "epi_count") * this.field("epi_price")
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

  inner(row, name) {
    return this.number(row.querySelector(`[data-field='${name}']`))
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

  setRole(container, role, text) {
    const element = container.querySelector(`[data-role='${role}']`)
    if (element) element.textContent = text
  }

  brl(value) {
    return value.toLocaleString("pt-BR", { style: "currency", currency: "BRL" })
  }

  decimal(value) {
    return value.toLocaleString("pt-BR", { minimumFractionDigits: 1, maximumFractionDigits: 1 })
  }
}
