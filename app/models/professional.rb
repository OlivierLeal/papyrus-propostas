class Professional < ApplicationRecord
  has_many :proposal_professionals, dependent: :restrict_with_error

  validates :name, presence: true
  validates :role, presence: true
  validates :rate_man_hour, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :rate_daily, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :social_charges_percent, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  # Apoio no BDI (cost_in_bdi): Diretoria e apoio da operação (administrativo, SMS…) já estão no
  # BDI/despesas administrativas — a IA dá 0 HH e 0 diárias. Desde 2026-10 (Charlene: "caso hajam
  # produtos a ser desenvolvidos por essas pessoas, aí sim cobramos o valor das horas", ex. o SMS
  # elaborando uma APR) o valor da hora/diária fica no cadastro e é cobrado quando a linha tem
  # esforço; antes ele era zerado e nunca dava pra cobrar.

  # Encargos sociais: gravado como fração (0.8), digitado como porcentagem (80) — ver
  # Spreadsheets::FactCatalog, que usa pra separar salário e encargos em planilha de formação de preço.
  def social_charges_percent_display
    social_charges_percent && (social_charges_percent * 100).round(2)
  end

  def social_charges_percent_display=(value)
    self.social_charges_percent = value.to_s.strip.presence && value.to_s.tr(",", ".").to_d / 100
  end

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
