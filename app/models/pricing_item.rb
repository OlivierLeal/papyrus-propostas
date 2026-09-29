# Item da precificação (2026-09-28, modelo da planilha real da Papyrus): uma frente do serviço com a
# sua equipe, os seus campos de logística e os seus custos fechados (ART, subcontratado "com
# logística", carta de veterinário...). Tudo aqui é custo direto — o item multiplica por BDI ×
# impostos, igual à planilha. É também a linha do Quadro de Preço discriminado.
class PricingItem < ApplicationRecord
  belongs_to :project_pricing
  belongs_to :pricing_enterprise, optional: true
  has_many :proposal_professionals, dependent: :nullify
  has_many :field_campaigns, -> { order(:position, :id) }, dependent: :destroy
  accepts_nested_attributes_for :field_campaigns, update_only: true

  validates :name, presence: true
  validate :enterprise_belongs_to_same_pricing, if: :pricing_enterprise_id_changed?

  def team_total
    proposal_professionals.sum(&:subtotal)
  end

  # Custo direto da logística dos campos, ANTES do multiplicador.
  def campaigns_cost
    field_campaigns.sum { |campaign| campaign.cost(project_pricing) }
  end

  # Quanto os campos do item cresceram por deslocamento até a hospedagem (dias ajustados ÷
  # planejados; 1 = nada) — ProposalProfessional#commute_extra_days alonga as diárias da equipe.
  def days_factor
    planned = field_campaigns.sum(&:days)
    planned.positive? ? field_campaigns.sum(&:effective_days) / planned : 1.to_d
  end

  def campaigns_total
    (campaigns_cost * project_pricing.multiplier).round(2)
  end

  def costs_total
    (costs_cost * project_pricing.multiplier).round(2)
  end

  def costs_cost
    costs.sum { |cost| cost["quantity"].to_d * cost["unit_value"].to_d }
  end

  def total
    team_total + campaigns_total + costs_total
  end

  # Custos fechados editados na tela (descrição, quantidade, valor unitário); linha sem descrição é
  # descartada — é como "remover" funciona, mesmo padrão de ProjectPricing#payment_schedule_items=.
  def cost_items=(items)
    items = items.respond_to?(:values) && !items.is_a?(Array) ? items.values : Array(items)
    self.costs = items.filter_map do |item|
      item = item.to_h.stringify_keys
      description = item["description"].to_s.strip
      next if description.blank?

      { "description" => description,
        "quantity" => decimal(item["quantity"], default: 1),
        "unit_value" => decimal(item["unit_value"], default: 0) }
    end
  end

  private

    def decimal(value, default:)
      text = value.to_s.strip.tr(",", ".")
      text.present? ? [ text.to_d, 0 ].max.to_f : default
    end

    def enterprise_belongs_to_same_pricing
      return if pricing_enterprise.nil? || pricing_enterprise.project_pricing_id == project_pricing_id

      errors.add(:pricing_enterprise, "não é desta proposta")
    end
end
