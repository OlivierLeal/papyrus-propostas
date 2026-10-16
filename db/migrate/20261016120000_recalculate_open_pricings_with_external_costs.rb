# Custos externos e terceirizados passaram a levar BDI × impostos (2026-10-16, Charlene: "o BDI
# precisa incidir sobre tudo, inclusive custos de terceiros"). Recalcula as propostas ainda abertas
# que têm custo externo, pra o total gravado bater com a tela. Aprovadas ficam como estão: preço
# aprovado nunca muda em silêncio (CLAUDE.md seção 5) — reabrir recalcula.
class RecalculateOpenPricingsWithExternalCosts < ActiveRecord::Migration[8.1]
  def up
    ProjectPricing.reset_column_information
    ProjectPricing.joins(:proposal).where.not(proposals: { status: "approved" })
      .where("jsonb_array_length(project_pricings.external_costs) > 0")
      .find_each(&:recalculate!)
  end

  def down; end
end
