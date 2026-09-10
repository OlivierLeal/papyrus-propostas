# Um documento do acervo histórico da Papyrus indexado para o RAG (CLAUDE.md seção 11.1).
#
# "Proposal" no nome é herança do domínio, mas nem todo registro aqui é uma proposta: o acervo
# é uma pasta por job, e dentro dela convivem a proposta da Papyrus, o TR do cliente, anexos
# técnicos e minutas contratuais. O que separa uns dos outros é o `role` — ver
# Rag::DocumentClassifier.
class HistoricalProposal < ApplicationRecord
  has_many :chunks, class_name: "HistoricalProposalChunk", dependent: :delete_all
  # Presente só quando a proposta saiu deste sistema (origin "sistema"/"revisao_manual") — o
  # acervo em disco não tem conversa de origem.
  belongs_to :conversation, optional: true
  # Quem clicou "Guardar" no card de revisão manual (ver #approve!) — vazio pra todo registro que
  # não passa por esse fluxo (acervo em disco, IndexApprovedProposalJob).
  belongs_to :submitted_by, class_name: "User", optional: true

  validates :source_sha256, presence: true, uniqueness: true
  validates :role, inclusion: { in: Rag::DocumentClassifier::ROLES.keys }

  REVIEW_STATUSES = %w[pending approved rejected].freeze
  validates :review_status, inclusion: { in: REVIEW_STATUSES }

  # Só o que a própria Papyrus escreveu pode servir de modelo de escrita para a IA. Recuperar
  # a especificação técnica do cliente como se fosse a voz da Papyrus ensinaria a IA a imitar
  # o cliente — no job da Petrobras o documento do cliente é 3x maior que a proposta.
  scope :voice_of_papyrus, -> { where(role: Rag::DocumentClassifier::VOICE_OF_PAPYRUS) }
  scope :current, -> { where(superseded: false) }
  # Documento histórico escrito por gente, distinto do que este sistema gerou.
  scope :from_archive, -> { where(origin: "acervo") }

  def voice_of_papyrus? = Rag::DocumentClassifier::VOICE_OF_PAPYRUS.include?(role)

  # Rótulo curto de origem, usado ao mostrar de onde veio um trecho recuperado.
  def source_label
    [ job_number, client_name, filename ].compact_blank.join(" · ")
  end

  def pending? = review_status == "pending"
  def approved? = review_status == "approved"
  def rejected? = review_status == "rejected"

  # Aprovar e indexar andam juntos, mesmo princípio de KnowledgeNote#approve!: um registro sem
  # chunk/embedding não é encontrável em busca nenhuma (SimilarJobFinder/Retriever/
  # SearchHistoricalArchiveTool só enxergam HistoricalProposalChunk), o que na prática equivale a
  # não ter sido aprovado — por isso não existe filtro de review_status em nenhuma dessas
  # consultas, a atomicidade já garante isso sozinha.
  def approve!(user)
    text = pending_text
    # Tudo numa transação só (mesmo padrão de KnowledgeNote#approve!): se embedar falhar
    # (chamada externa), o status e o pending_text voltam exatamente como estavam — o consultor
    # tenta de novo em vez de ficar com um registro "aprovado" mas sem chunk/vetor nenhum.
    transaction do
      update!(review_status: "approved", submitted_by: user, pending_text: nil)
      Rag::ProposalIndexer.new(self, text).call!
    end
  end

  # Mantém o registro como rastro (igual KnowledgeNote rejeitada) — só o texto pendente é
  # descartado, não há motivo pra continuar guardando o conteúdo de algo que não foi aprovado.
  def reject!(user)
    update!(review_status: "rejected", submitted_by: user, pending_text: nil)
  end
end
