class StudyType < ApplicationRecord
  has_many :study_templates, dependent: :destroy
  # Uma conversa pode ter N tipos de estudo (2026-09, ver conversation_study_types) —
  # restrict_with_error continua na tabela de junção: não dá pra apagar um tipo em uso em
  # NENHUMA proposta, mesma garantia de sempre.
  has_many :conversation_study_types, dependent: :restrict_with_error
  has_many :conversations, through: :conversation_study_types

  validates :name, presence: true
  validates :code, presence: true, uniqueness: true

  # A IA recebe o menu de códigos cadastrados e é instruída a devolver um deles (ver
  # ProcessEtJob#prompt), mas ela erra de duas formas previsíveis: devolve o NOME em vez do código
  # ("EIA-RIMA" no lugar de "eia_rima") ou inventa um código que não existe ("eai", achado ao vivo
  # na conversa 31 — Estudo Ambiental Intermediário, que a Papyrus simplesmente nunca cadastrou).
  # O primeiro caso é ruído de formato e o sistema resolve sozinho; o segundo é falta de cadastro
  # e precisa de gente (ver Conversation#assign_study_types_from_findings!).
  def self.match_ai_value(value)
    key = normalize_key(value)
    return nil if key.blank?

    all.to_a.find { |type| normalize_key(type.code) == key || normalize_key(type.name) == key }
  end

  def self.normalize_key(value)
    I18n.transliterate(value.to_s).downcase.gsub(/[^a-z0-9]+/, " ").strip.tr(" ", "_")
  end
end
