class Professional < ApplicationRecord
  has_many :study_templates, dependent: :destroy
  has_many :proposal_professionals, dependent: :restrict_with_error

  validates :name, presence: true
  validates :role, presence: true
  validates :rate_office, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :rate_field, presence: true, numericality: { greater_than_or_equal_to: 0 }

  scope :active, -> { where(active: true) }
end
