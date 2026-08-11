class ProjectPricing < ApplicationRecord
  belongs_to :proposal
  has_many :proposal_professionals, dependent: :destroy
  accepts_nested_attributes_for :proposal_professionals, update_only: true

  validates :bdi, :tax_multiplier, presence: true, numericality: { greater_than: 0 }
  validates :distance_km, :rental_per_day, :meal_per_day, :fuel_total,
            presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :logistics_days, presence: true, numericality: { greater_than_or_equal_to: 0 }

  def professionals_total
    proposal_professionals.sum(&:subtotal)
  end

  # C4 = logística = (aluguel/dia + alimentação/dia) × dias de campo + combustível
  def logistics_total
    ((rental_per_day + meal_per_day) * logistics_days) + fuel_total
  end

  # C5 = custos externos (ARTs, terceiros: fauna, flora, drone) — lançados manualmente por proposta
  def external_costs_total
    external_costs.sum { |item| item["value"].to_f }
  end

  # C6 = TOTAL = Σ profissionais + logística + externos
  def recalculate!
    proposal_professionals.each { |pp| pp.recalculate_subtotal(bdi: bdi, tax_multiplier: tax_multiplier) }
    ActiveRecord::Base.transaction do
      proposal_professionals.each(&:save!)
      update!(total_value: (professionals_total + logistics_total + external_costs_total).round(2))
    end
  end

  def payment_schedule_amounts
    payment_schedule.map do |item|
      item.merge("amount" => (total_value * item["percentage"].to_f / 100).round(2))
    end
  end
end
