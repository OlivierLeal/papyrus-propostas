class Professional < ApplicationRecord
  has_many :proposal_professionals, dependent: :restrict_with_error

  validates :name, presence: true
  validates :role, presence: true
  validates :rate_man_hour, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :rate_daily, presence: true, numericality: { greater_than_or_equal_to: 0 }

  scope :active, -> { where(active: true) }
  # Entra em toda proposta independente do que a IA sugerir (ver Proposal#ensure_always_included_lines!)
  # — Diretoria/Coordenação da Papyrus, não algo que varia conforme o ET.
  scope :always_included, -> { where(always_included: true) }
end
