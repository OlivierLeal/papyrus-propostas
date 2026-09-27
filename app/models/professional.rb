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

  after_update_commit :recalculate_open_pricings, if: -> { saved_change_to_rate_man_hour? || saved_change_to_rate_daily? }

  private
    # O subtotal de cada linha é gravado (ProjectPricing#recalculate!), não calculado na hora — sem
    # isto, preencher o valor da hora-homem/diária em Configurações DEPOIS de a proposta existir
    # deixava a Tela de Precificação com o valor antigo (R$ 0,00) até alguém clicar em "Recalcular
    # preço" (relato do consultor, 2026-09). Só propostas não aprovadas: preço aprovado fica
    # congelado com o valor da época.
    def recalculate_open_pricings
      ProjectPricing.joins(:proposal, :proposal_professionals)
        .where(proposal_professionals: { professional_id: id })
        .where.not(proposals: { status: "approved" })
        .distinct.find_each(&:recalculate!)
    end
end
