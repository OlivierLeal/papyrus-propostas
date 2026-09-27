# Ficha estruturada de um job do acervo: serviço, valor, prazo e equipe (função, horas-homem,
# diárias), extraída do que a proposta da Papyrus ESCREVEU — ver Rag::PrecedentExtractor.
#
# É REFERÊNCIA, nunca preço (CLAUDE.md seção 1): serve pro consultor e pra IA terem noção de porte
# e composição de equipe em projetos parecidos. Quem calcula o preço desta proposta continua sendo
# o motor (ProjectPricing), a partir do que o consultor confirma.
class JobPrecedent < ApplicationRecord
  has_neighbors :embedding

  STATUSES = %w[ok no_data failed].freeze

  validates :job_number, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }

  scope :searchable, -> { where(status: "ok").where.not(embedding: nil) }

  def team_members
    Array(team).map { |member| member.to_h.stringify_keys }
  end

  def total_man_hours
    team_members.sum { |member| member["horas_homem"].to_f }
  end

  def total_field_days
    team_members.sum { |member| member["diarias"].to_f }
  end

  def reference
    [ "acervo Papyrus: projeto #{job_number}", client_name, year ].compact_blank.join(" — ")
  end
end
