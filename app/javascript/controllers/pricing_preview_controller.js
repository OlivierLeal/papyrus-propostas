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

    // Campos primeiro: o deslocamento até a hospedagem alonga os dias de cada campo, e a equipe do
    // item cresce na mesma proporção (FieldCampaign#effective_days, ProposalProfessional#commute_extra_days).
    const planned = {}
    const effective = {}
    this.campaignTargets.forEach((row) => {
      const days = this.inner(row, "days")
      const itemId = row.dataset.itemId
      planned[itemId] = (planned[itemId] || 0) + days
      effective[itemId] = (effective[itemId] || 0) + this.effectiveDays(days, this.inner(row, "commute_hours"), row)
      this.updateCommuteNote(row)
    })

    let hours = 0
    let days = 0
    let team = 0
    this.lineTargets.forEach((row) => {
      const lineHours = this.number(row.querySelector("input[name$='[man_hours]']"))
      const lineDays = this.number(row.querySelector("input[name$='[field_days]']"))
      const itemSelect = row.querySelector("[data-role='line-item']")
      const itemId = itemSelect ? itemSelect.value : null
      const factor = itemId && planned[itemId] > 0 ? effective[itemId] / planned[itemId] : 1
      const extra = lineDays > 0 ? Math.ceil(this.round6(lineDays * (factor - 1) * 2)) / 2 : 0
      const extraCell = row.querySelector("[data-role='commute-extra']")
      if (extraCell) {
        extraCell.hidden = !(extra > 0)
        extraCell.textContent = `+${this.short(extra)} desloc.`
      }
      const subtotal = this.round((lineHours * Number(row.dataset.rateHour) + (lineDays + extra) * Number(row.dataset.rateDay)) * multiplier)
      hours += lineHours
      days += lineDays
      team += subtotal
      if (itemId) bucket(itemId).team += subtotal
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
    const days = this.effectiveDays(this.inner(row, "days"), this.inner(row, "commute_hours"), row)
    const tripDays = days + this.inner(row, "travel_days")
    const vehicles = this.inner(row, "vehicles")
    const typeSelect = row.querySelector("[data-field='vehicle_type']")
    const rental = typeSelect && typeSelect.value === "4x4" ? this.field("rental_4x4_per_day") : this.field("rental_per_day")
    const consumption = this.field("vehicle_consumption_km_per_liter") || 1
    const distance = row.dataset.distanceKm ? Number(row.dataset.distanceKm) : this.field("distance_km")
    const km = distance * 2 + (this.field("daily_km") + this.inner(row, "commute_km") * 2) * days

    return vehicles * tripDays * rental +
      km * vehicles / consumption * this.field("fuel_price_per_liter") +
      people * tripDays * this.field("meal_per_person_per_day") +
      people * Math.max(tripDays - 1, 0) * this.lodgingRate(row) +
      this.inner(row, "tolls") * this.field("toll_price") +
      this.inner(row, "washes") * this.field("wash_price") +
      this.inner(row, "uber_trips") * this.field("uber_price") +
      this.inner(row, "mateiro_days") * this.field("mateiro_per_day") +
      this.inner(row, "epi_count") * this.field("epi_price")
  }

  // FieldCampaign#lodging_rate
  lodgingRate(row) {
    const mode = this.modeOf(row)
    if (mode === "cliente") return 0
    if (mode === "hotel" || mode === "alojamento") return this.inner(row, "lodging_price_per_night")
    return this.field("lodging_per_person_per_night")
  }

  modeOf(row) {
    const select = row.querySelector("[data-field='lodging_mode']")
    return select ? select.value : ""
  }

  // Constantes vêm do servidor (data-* do aviso), pra não duplicar os números aqui.
  commuteRules(row) {
    const note = row.querySelector("[data-role='commute-note']")
    const data = note ? note.dataset : {}
    return {
      workday: Number(data.workday) || 8,
      tolerance: Number(data.tolerance) || 0.5,
      warning: Number(data.warning) || 2,
      minProductive: Number(data.minProductive) || 1
    }
  }

  // FieldCampaign#effective_days — dias × jornada ÷ horas úteis, pra cima em dias inteiros.
  effectiveDays(days, commuteHours, row) {
    const rules = this.commuteRules(row)
    const daily = commuteHours > rules.tolerance ? commuteHours * 2 : 0
    if (daily === 0 || days === 0) return days
    const productive = Math.max(rules.workday - daily, rules.minProductive)
    return Math.max(Math.ceil(this.round6(days * rules.workday / productive)), days)
  }

  // Mesmo texto de ProposalsHelper#commute_note.
  updateCommuteNote(row) {
    const note = row.querySelector("[data-role='commute-note']")
    if (!note) return
    const rules = this.commuteRules(row)
    const days = this.inner(row, "days")
    const commute = this.inner(row, "commute_hours")
    const effective = this.effectiveDays(days, commute, row)
    const parts = []
    if (commute > rules.tolerance) {
      const productive = Math.max(rules.workday - commute * 2, rules.minProductive)
      let text = `Deslocamento de ${this.hours(commute)} por trecho: ${this.short(productive)}h úteis na jornada de ${rules.workday}h → ` +
        `${this.short(days)} → ${this.short(effective)} dias em campo`
      if (effective > days) text += ` (+${this.short(effective - days)}; as diárias da equipe do item crescem junto)`
      parts.push([`${text}.`, "text-base-content/60"])
    }
    if (commute > rules.warning) {
      parts.push([` Mais de ${rules.warning}h por trecho — ir e voltar todo dia é inviável; procure hospedagem mais perto da área ou alojamento.`, "text-warning"])
    }
    const nights = Math.max(effective + this.inner(row, "travel_days") - 1, 0)
    if (this.modeOf(row) === "" && nights > 0) {
      parts.push([` Hospedagem não escolhida — usando ${this.brl(this.field("lodging_per_person_per_night"))}/noite padrão.`, "text-warning"])
    }
    note.replaceChildren(...parts.map(([text, css]) => {
      const span = document.createElement("span")
      span.className = css
      span.textContent = text
      return span
    }))
  }

  hours(value) {
    const minutes = Math.round(value * 60)
    if (minutes < 60) return `${minutes} min`
    const rest = minutes % 60
    return `${Math.floor(minutes / 60)}h${rest ? String(rest).padStart(2, "0") : ""}`
  }

  round6(value) {
    return Math.round(value * 1e6) / 1e6
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

  // Igual ProposalsHelper#decimal_label: "5", "5,5".
  short(value) {
    return value.toLocaleString("pt-BR", { maximumFractionDigits: 1 })
  }

  decimal(value) {
    return value.toLocaleString("pt-BR", { minimumFractionDigits: 1, maximumFractionDigits: 1 })
  }
}
