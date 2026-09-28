# Preço discriminado por etapa (2026-09-28, proposta VESTAS/conversa 63: o ET pede "custos
# discriminados, permitindo identificar os valores relativos às principais etapas e estudos").
# Cada linha da equipe ganha uma etapa; o subpreço de cada etapa é calculado em Ruby
# (ProjectPricing#price_breakdown_rows). O quadro de preço só sai aberto quando pedido.
class AddPriceBreakdown < ActiveRecord::Migration[8.1]
  def change
    add_column :proposal_professionals, :stage, :string
    add_column :project_pricings, :price_breakdown, :boolean, default: false, null: false
  end
end
