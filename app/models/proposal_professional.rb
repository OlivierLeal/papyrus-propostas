class ProposalProfessional < ApplicationRecord
  belongs_to :project_pricing
  belongs_to :professional

  validates :deliverable_name, presence: true
  validates :hours_office, :hours_field, presence: true, numericality: { greater_than_or_equal_to: 0 }

  # C1 = horas escritório × taxa escritório; C2 = horas campo × taxa campo
  # C3 = subtotal do profissional = (C1 + C2) × BDI × impostos (ver CLAUDE.md seção 5)
  def recalculate_subtotal(bdi:, tax_multiplier:)
    c1 = hours_office * professional.rate_office
    c2 = hours_field * professional.rate_field
    self.subtotal = ((c1 + c2) * bdi * tax_multiplier).round(2)
  end
end
