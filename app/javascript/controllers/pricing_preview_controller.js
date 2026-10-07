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
    "summaryTotal", "summaryTeam", "summaryLogistics", "summaryItemCosts", "installment", "dirty", "approve",
    "summaryDirect", "summaryBdi", "summaryTaxes", "compositionTotal"
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
      // Dias de viagem também viram diária de quem vai a campo (PricingItem#days_factor).
      effective[itemId] = (effective[itemId] || 0) + this.effectiveDays(days, this.inner(row, "commute_hours"), row) + this.inner(row, "travel_days")
      this.updateCommuteNote(row)
    })

    // A tela mostra valores PUROS por linha (2026-09-30, pedido do cliente) e aplica BDI e impostos só
    // no resumo — ProjectPricing#price_composition. O total continua sendo a soma das partes COM margem,
    // arredondadas como no Ruby (linha a linha / por item), pra bater com o servidor.
    const perItemRaw = {}
    const raw = (id) => (perItemRaw[id] ||= { team: 0, campaigns: 0, costs: 0 })
    let hours = 0
    let days = 0
    let team = 0
    let teamDirect = 0
    this.lineTargets.forEach((row) => {
      // Item espelhado da planilha do cliente: a linha tem o esforço POR UNIDADE, e o total é
      // por-unidade × quantidade do cliente (ProposalProfessional#apply_per_unit_effort, 2 casas).
      const unitQty = this.unitQuantity(row)
      const perUnitHours = row.querySelector("input[name$='[man_hours_per_unit]']")
      const perUnitDays = row.querySelector("input[name$='[field_days_per_unit]']")
      const lineHours = perUnitHours ? this.round(this.number(perUnitHours) * unitQty) : this.number(row.querySelector("input[name$='[man_hours]']"))
      const lineDays = perUnitDays ? this.round(this.number(perUnitDays) * unitQty) : this.number(row.querySelector("input[name$='[field_days]']"))
      const hoursNote = row.querySelector("[data-role='per-unit-hours']")
      if (hoursNote) hoursNote.textContent = `por unid. · total ${this.short(lineHours)}`
      const daysNote = row.querySelector("[data-role='per-unit-days']")
      if (daysNote) daysNote.textContent = `por unid. · total ${this.short(lineDays)}`
      const itemSelect = row.querySelector("[data-role='line-item']")
      const itemId = itemSelect ? itemSelect.value : null
      const factor = itemId && planned[itemId] > 0 ? effective[itemId] / planned[itemId] : 1
      const extra = lineDays > 0 ? Math.ceil(this.round6(lineDays * (factor - 1) * 2)) / 2 : 0
      const extraCell = row.querySelector("[data-role='commute-extra']")
      if (extraCell) {
        extraCell.hidden = !(extra > 0)
        extraCell.textContent = `+${this.short(extra)} desloc.`
      }
      // Valores desta proposta (terceirizado): em branco vale o cadastro (ProposalProfessional#hour_rate).
      const ownRate = (role, fallback) => {
        const input = row.querySelector(`[data-role='${role}']`)
        return input && input.value.trim() !== "" ? this.number(input) : fallback
      }
      const hourRate = ownRate("rate-hour", Number(row.dataset.rateHour))
      const dayRate = ownRate("rate-day", Number(row.dataset.rateDay))
      const fixed = ownRate("fixed-amount", 0)
      const hourLabel = row.querySelector("[data-role='hour-rate-label']")
      if (hourLabel) hourLabel.textContent = `× ${this.brl(hourRate)}/h`
      const dayLabel = row.querySelector("[data-role='day-rate-label']")
      if (dayLabel) dayLabel.textContent = `× ${this.brl(dayRate)}/dia`
      const lineDirect = fixed + lineHours * hourRate + (lineDays + extra) * dayRate
      const subtotal = this.round(lineDirect * multiplier)
      hours += lineHours
      days += lineDays
      team += subtotal
      teamDirect += lineDirect
      if (itemId) {
        bucket(itemId).team += subtotal
        raw(itemId).team += lineDirect
      }
      const cell = row.querySelector("[data-role='subtotal']")
      if (cell) cell.textContent = this.brl(this.round(lineDirect))
    })

    let logistics = 0
    let logisticsDirect = 0
    this.campaignTargets.forEach((row) => {
      const rawCampaign = this.campaignCost(row)
      logisticsDirect += rawCampaign
      raw(row.dataset.itemId).campaigns += rawCampaign
      bucket(row.dataset.itemId).campaigns += rawCampaign * multiplier
      const cell = row.querySelector("[data-role='campaign-total']")
      if (cell) cell.textContent = this.brl(this.round(rawCampaign))
    })

    let itemCosts = 0
    let itemCostsDirect = 0
    this.itemCostTargets.forEach((row) => {
      const rawCost = this.inner(row, "quantity") * this.inner(row, "unit_value")
      itemCostsDirect += rawCost
      raw(row.dataset.itemId).costs += rawCost
      bucket(row.dataset.itemId).costs += rawCost * multiplier
      const cell = row.querySelector("[data-role='cost-total']")
      if (cell) cell.textContent = this.brl(this.round(rawCost))
    })

    this.itemTargets.forEach((card) => {
      const values = raw(card.dataset.itemId)
      this.setRole(card, "item-team", this.brl(this.round(values.team)))
      this.setRole(card, "item-campaigns", this.brl(this.round(values.campaigns)))
      this.setRole(card, "item-costs", this.brl(this.round(values.costs)))
      this.setRole(card, "item-total", this.brl(this.round(values.team + values.campaigns + values.costs)))
    })
    // Cabeçalho de cada item na tabela da equipe (agrupada por item).
    this.element.querySelectorAll("[data-item-team-total]").forEach((element) => {
      element.textContent = this.brl(this.round(raw(element.dataset.itemTeamTotal).team))
    })
    // PricingItem#campaigns_total/#costs_total arredondam por item.
    Object.values(perItem).forEach((values) => {
      logistics += this.round(values.campaigns)
      itemCosts += this.round(values.costs)
    })

    const total = this.round(team + logistics + itemCosts + this.externalTotalValue)
    const teamRounded = this.round(teamDirect)
    const logisticsRounded = this.round(logisticsDirect)
    const itemCostsRounded = this.round(itemCostsDirect)
    const direct = this.round(teamRounded + logisticsRounded + itemCostsRounded)
    const bdiAmount = this.round(direct * (this.field("bdi") - 1))

    this.set(this.teamHoursTargets, `${this.decimal(hours)} HH`)
    this.set(this.teamDaysTargets, this.decimal(days))
    this.set(this.teamTotalTargets, this.brl(teamRounded))
    this.set(this.logisticsTargets, this.brl(logisticsRounded))
    this.set(this.summaryTeamTargets, this.brl(teamRounded))
    this.set(this.summaryLogisticsTargets, this.brl(logisticsRounded))
    this.set(this.summaryItemCostsTargets, this.brl(itemCostsRounded))
    this.set(this.summaryDirectTargets, this.brl(direct))
    this.set(this.summaryBdiTargets, this.brl(bdiAmount))
    this.set(this.summaryTaxesTargets, this.brl(this.round(team + logistics + itemCosts - direct - bdiAmount)))
    this.set(this.summaryTotalTargets, this.brl(total))
    this.set(this.compositionTotalTargets, this.brl(total))
    this.updateInstallments(total)
    this.dirtyTargets.forEach((element) => { element.hidden = false })
    // Aprovar com alteração não salva aprovaria o preço ANTERIOR (o servidor só conhece o salvo).
    this.approveTargets.forEach((button) => {
      button.disabled = true
      button.title = "Salve antes de aprovar — há alterações não salvas"
    })

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

  // Quantidade do cliente do item da linha: o campo do item (se o consultor estiver mudando) ou a salva.
  unitQuantity(row) {
    const itemSelect = row.querySelector("[data-role='line-item']")
    const input = itemSelect && this.element.querySelector(`[data-pricing-preview-target='item'][data-item-id='${itemSelect.value}'] [data-role='client-quantity']`)
    return input ? this.number(input) : Number(row.dataset.unitQty) || 0
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
