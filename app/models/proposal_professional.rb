class ProposalProfessional < ApplicationRecord
  belongs_to :project_pricing
  belongs_to :professional

  validates :deliverable_name, presence: true
  validates :man_hours, :field_days, presence: true, numericality: { greater_than_or_equal_to: 0 }

  # C1 = horas-homem × valor da hora-homem; C2 = diárias × valor da diária
  # C3 = subtotal do profissional = (C1 + C2) × BDI × impostos (ver CLAUDE.md seção 5)
  def recalculate_subtotal(bdi:, tax_multiplier:)
    c1 = man_hours * professional.rate_man_hour
    c2 = field_days * professional.rate_daily
    self.subtotal = ((c1 + c2) * bdi * tax_multiplier).round(2)
  end
end
