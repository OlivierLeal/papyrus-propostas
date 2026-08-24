# Um trecho recuperável do acervo, com seu vetor. O corte é por seção do documento
# (Rag::SectionChunker), não a cada N caracteres, e cada trecho carrega o próprio título de
# seção no texto — sem isso um pedaço do meio de "ESCOPO E METODOLOGIA" recuperado sozinho
# não diz de que parte da proposta veio.
class HistoricalProposalChunk < ApplicationRecord
  has_neighbors :embedding

  belongs_to :historical_proposal

  validates :content, presence: true

  delegate :role, :client_name, :job_number, :source_label, to: :historical_proposal

  scope :embedded, -> { where.not(embedded_at: nil) }
  scope :pending_embedding, -> { where(embedded_at: nil) }

  # Trecho com dado identificável (CPF, CNPJ, registro de conselho, contato) fica disponível
  # mas pode ser excluído da recuperação quando o uso não justificar — CLAUDE.md, LGPD.
  scope :without_sensitive, -> { where(sensitive: false) }

  # Texto de modelo repetido em quase toda proposta (obrigações, validade, prazo, condições de
  # pagamento). Continua recuperável numa busca direta, mas fica fora da comparação entre jobs —
  # ver Rag::BoilerplateDetector.
  scope :without_boilerplate, -> { where(boilerplate: false) }

  scope :indexable, -> { joins(:historical_proposal).merge(HistoricalProposal.current) }
end
