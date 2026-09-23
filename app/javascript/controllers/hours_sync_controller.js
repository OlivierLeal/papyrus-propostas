import { Controller } from "@hotwired/stimulus"

// Um único campo "Horas" visível alimentando hours_office/hours_field escondidos (2026-09,
// pedido do consultor: "não precisa de campo de horas escritório e horas campo, é o mesmo
// valor" — na digitação manual da Tela de Precificação ele sempre preenchia os dois com o
// mesmo número, então dois campos era redundante). O motor de cálculo continua recebendo os
// dois valores separados (C1/C2 usam rate_office/rate_field, que continuam diferentes por
// profissional — decisão de produto ainda pendente, não mexida aqui) — só a ENTRADA manual foi
// simplificada. A sugestão da IA e os study_templates continuam podendo gravar valores
// diferentes nos dois campos (não passam por este controller, só a edição na tela).
export default class extends Controller {
  static targets = ["visible", "hidden"]

  connect() {
    this.sync()
  }

  sync() {
    const value = this.visibleTarget.value
    this.hiddenTargets.forEach((hidden) => { hidden.value = value })
  }
}
