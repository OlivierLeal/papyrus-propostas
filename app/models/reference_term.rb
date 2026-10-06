# Um TR (ou roteiro de conteúdo mínimo / instrução normativa com conteúdo de estudo) da biblioteca
# da Papyrus — ver a migração CreateReferenceTerms. Importado por ReferenceTerms::Importer, levado
# pra produção por script/reference_terms/export.rb.
class ReferenceTerm < ApplicationRecord
  has_neighbors :embedding

  STATUSES = %w[active ignored].freeze

  validates :sha256, :title, :filename, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :active, -> { where(status: "active") }
  scope :searchable, -> { active.where.not(embedding: nil) }

  # Os mais parecidos com o serviço desta proposta (Conversation#service_descriptor). O órgão e a UF
  # vão junto no texto: quem decide se serve pra ESTE caso é a IA, com o resto do contexto.
  def self.similar_to(descriptor, limit: 5, embedder: Rag::Embedder.new)
    return none if descriptor.blank? || !searchable.exists?

    searchable.nearest_neighbors(:embedding, embedder.embed_query(descriptor), distance: "cosine").first(limit)
  end

  def label
    [ title, ("#{organ}#{"/#{uf}" if uf.present?}" if organ.present?) ].compact.join(" — ")
  end

  def document_profile
    tipo = TermOfReferenceAnnex::TYPES.include?(document_type) ? document_type : "Termo de Referência"
    { "tipo" => tipo, "numero" => number.presence, "anexar" => true, "motivo" => "biblioteca de TRs da Papyrus" }
  end
end
