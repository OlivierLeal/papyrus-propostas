class LogisticsConfig < ApplicationRecord
  validates :name, presence: true
  validates :rental_per_day, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :fuel_price_per_liter, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :lodging_per_day, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :meal_per_day, presence: true, numericality: { greater_than_or_equal_to: 0 }

  scope :active, -> { where(active: true) }
end
