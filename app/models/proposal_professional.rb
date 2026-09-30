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

  # Item espelhado da planilha do cliente (PricingItem#mirrored?): o esforço é digitado POR UNIDADE
  # e o total (o que todo o resto do sistema usa) é por-unidade × quantidade do cliente.
  before_save :apply_per_unit_effort

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
    (direct_cost(days_factor) * bdi * tax_multiplier).round(2)
  end

  # C1 + C2: horas-homem × valor/hora + diárias (com o acréscimo de deslocamento) × valor/diária,
  # ANTES de BDI e impostos — é o "custo direto" da composição do preço na tela.
  def direct_cost(days_factor = nil)
    man_hours * professional.rate_man_hour + (field_days + commute_extra_days(days_factor)) * professional.rate_daily
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

  def per_unit? = pricing_item&.mirrored? || false

  private
    def apply_per_unit_effort
      # Linha comum que não mudou de item: nada a fazer (e sem carregar o item — recalculate! salva
      # todas as linhas da proposta).
      return if man_hours_per_unit.nil? && field_days_per_unit.nil? && !pricing_item_id_changed?

      quantity = association(:pricing_item).loaded? ? pricing_item&.client_quantity : PricingItem.where(id: pricing_item_id).pick(:client_quantity)
      unless quantity&.positive?
        self.man_hours_per_unit = self.field_days_per_unit = nil
        return
      end

      # Quem mudou vale: total editado sozinho (junção de linhas, linha que acabou de entrar no item)
      # recalcula o por-unidade; senão o por-unidade manda no total.
      self.man_hours_per_unit = man_hours / quantity if man_hours_per_unit.nil? || (man_hours_changed? && !man_hours_per_unit_changed?)
      self.field_days_per_unit = field_days / quantity if field_days_per_unit.nil? || (field_days_changed? && !field_days_per_unit_changed?)
      self.man_hours = (man_hours_per_unit * quantity).round(2)
      self.field_days = (field_days_per_unit * quantity).round(2)
    end

    def item_belongs_to_same_pricing
      return if pricing_item.nil? || pricing_item.project_pricing_id == project_pricing_id

      errors.add(:pricing_item, "não é desta proposta")
    end
end
