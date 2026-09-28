# Empreendimento da proposta (2026-09-28) — uma proposta pode cobrir mais de um (ex.: 3 BESS da
# Newave). Itens ligados a um empreendimento somam só pra ele; itens sem empreendimento são comuns e
# rateados (ProjectPricing#enterprise_totals). Sem nenhum cadastrado, a proposta é de um só.
class PricingEnterprise < ApplicationRecord
  belongs_to :project_pricing
  has_many :pricing_items, dependent: :nullify

  validates :name, presence: true
end
