# Uma norma legal do CAL (Ius Natura, CLAUDE.md seção 11.2) baixada, lida e guardada — em vez de
# rebaixar/reprocessar a mesma norma do zero toda vez que outra proposta cita ela (SearchLegalNormsTool
# consulta esta tabela ANTES de bater no CAL). `codigo` é a mesma chave que a ferramenta já expõe
# pra IA como `codigo_norma`, não um id novo.
#
# Sem curadoria antes de virar consultável (diferente de KnowledgeNote): o texto aqui é legislação
# oficial, baixada direto da fonte — não é a IA "achando" algo numa conversa. Mesmo raciocínio de
# HistoricalProposal/Rag::ProposalIndexer, que também embedam direto, sem gate humano.
class LegalNorm < ApplicationRecord
  has_many :chunks, class_name: "LegalNormChunk", dependent: :delete_all
  has_one_attached :pdf

  validates :codigo, presence: true, uniqueness: true
end
