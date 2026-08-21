# Um documento do acervo histórico da Papyrus indexado para o RAG (CLAUDE.md seção 11.1).
#
# "Proposal" no nome é herança do domínio, mas nem todo registro aqui é uma proposta: o acervo
# é uma pasta por job, e dentro dela convivem a proposta da Papyrus, o TR do cliente, anexos
# técnicos e minutas contratuais. O que separa uns dos outros é o `role` — ver
# Rag::DocumentClassifier.
class HistoricalProposal < ApplicationRecord
  has_many :chunks, class_name: "HistoricalProposalChunk", dependent: :delete_all

  validates :source_sha256, presence: true, uniqueness: true
  validates :role, inclusion: { in: Rag::DocumentClassifier::ROLES.keys }

  # Só o que a própria Papyrus escreveu pode servir de modelo de escrita para a IA. Recuperar
  # a especificação técnica do cliente como se fosse a voz da Papyrus ensinaria a IA a imitar
  # o cliente — no job da Petrobras o documento do cliente é 3x maior que a proposta.
  scope :voice_of_papyrus, -> { where(role: Rag::DocumentClassifier::VOICE_OF_PAPYRUS) }
  scope :current, -> { where(superseded: false) }

  def voice_of_papyrus? = Rag::DocumentClassifier::VOICE_OF_PAPYRUS.include?(role)

  # Rótulo curto de origem, usado ao mostrar de onde veio um trecho recuperado.
  def source_label
    [ job_number, client_name, filename ].compact_blank.join(" · ")
  end
end
