class ProposalProfessional < ApplicationRecord
  # `stage` (rótulo de etapa em texto, 2026-09-28 manhã) virou PricingItem na mesma tarde; a coluna
  # fica no banco até a migração de limpeza.
  self.ignored_columns += %w[stage]

  belongs_to :project_pricing
  belongs_to :professional
  belongs_to :pricing_item, optional: true

  # Toda linha pertence a um item — sem item informado, cai no primeiro da proposta.
  # (Checa o id antes pra não carregar o item de cada linha a cada save — recalculate! salva todas.)
  before_validation { self.pricing_item = project_pricing&.default_item if pricing_item_id.nil? && pricing_item.nil? }
  validate :item_belongs_to_same_pricing, if: :pricing_item_id_changed?

  validates :deliverable_name, presence: true
  validates :man_hours, :field_days, presence: true, numericality: { greater_than_or_equal_to: 0 }

  # C1 = horas-homem × valor da hora-homem; C2 = diárias × valor da diária
  # C3 = subtotal do profissional = (C1 + C2) × BDI × impostos (ver CLAUDE.md seção 5)
  # Quem é fixo (always_included — Diretoria/Coordenação) não sai da equipe. Se a IA deu mais de
  # uma linha pra mesma pessoa fixa, as extras podem sair; a última fica.
  def removable?
    return true unless professional.always_included

    project_pricing.proposal_professionals.where(professional_id: professional_id).where.not(id: id).exists?
  end

  # days_factor: PricingItem#days_factor do item desta linha — quem já tem os itens carregados
  # (ProjectPricing#recalculate!) passa pronto; sem ele, lê do item.
  def recalculate_subtotal(bdi:, tax_multiplier:, days_factor: nil)
    self.subtotal = expected_subtotal(bdi: bdi, tax_multiplier: tax_multiplier, days_factor: days_factor)
  end

  def expected_subtotal(bdi:, tax_multiplier:, days_factor: nil)
    c1 = man_hours * professional.rate_man_hour
    c2 = (field_days + commute_extra_days(days_factor)) * professional.rate_daily
    ((c1 + c2) * bdi * tax_multiplier).round(2)
  end

  # Hospedagem longe da área alonga os campos do item (FieldCampaign#effective_days) — quem vai a
  # campo nesse item ganha diárias na mesma proporção: diárias × (dias ajustados ÷ planejados − 1),
  # arredondado pra cima em meia diária. field_days continua sendo o PLANEJADO que o consultor
  # digitou; o acréscimo é derivado, então trocar de hotel atualiza sozinho.
  def commute_extra_days(days_factor = nil)
    return 0.to_d unless field_days.positive?

    days_factor ||= pricing_item&.days_factor || 1
    return 0.to_d unless days_factor > 1

    (field_days * (days_factor - 1) * 2).round(6).ceil.to_d / 2
  end

  private
    def item_belongs_to_same_pricing
      return if pricing_item.nil? || pricing_item.project_pricing_id == project_pricing_id

      errors.add(:pricing_item, "não é desta proposta")
    end
end
