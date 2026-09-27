class ProposalProfessional < ApplicationRecord
  belongs_to :project_pricing
  belongs_to :professional

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

  def recalculate_subtotal(bdi:, tax_multiplier:)
    self.subtotal = expected_subtotal(bdi: bdi, tax_multiplier: tax_multiplier)
  end

  def expected_subtotal(bdi:, tax_multiplier:)
    c1 = man_hours * professional.rate_man_hour
    c2 = field_days * professional.rate_daily
    ((c1 + c2) * bdi * tax_multiplier).round(2)
  end
end
