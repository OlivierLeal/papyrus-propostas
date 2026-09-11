# Um trecho recuperável de uma LegalNorm, com seu vetor — mesmo mecanismo de HistoricalProposalChunk,
# mas sem os flags de sensibilidade/preço/boilerplate (legislação é pública, não tem dado de
# cliente pra proteger nem texto repetido de modelo de proposta pra filtrar).
class LegalNormChunk < ApplicationRecord
  has_neighbors :embedding

  belongs_to :legal_norm

  validates :content, presence: true

  scope :embedded, -> { where.not(embedded_at: nil) }
  scope :pending_embedding, -> { where(embedded_at: nil) }
end
