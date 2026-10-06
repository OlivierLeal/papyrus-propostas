# Um TR do estudo (Termo de Referência do órgão competente) proposto pra esta proposta quando o
# cliente não enviou um (2026-10, Sara: "o TR tem que vir como anexo e não no escopo"; consultor: o
# TR pode vir do CAL ou da internet). O sistema procura sozinho (FindTermOfReferenceJob) e o
# consultor indica pelo chat (SetTermOfReferenceTool); nos dois casos quem decide é o consultor, no
# card: anexar o TR errado numa proposta é caro.
#
# Aceito, o arquivo fica em `file` e passa a ser o TR da conversa (Conversation#term_of_reference_
# attachments): vira o Anexo I do .docx e o ProcessTrJob lê ele como leria o TR do setup.
class TermOfReferenceCandidate < ApplicationRecord
  SOURCES = %w[biblioteca cal internet consultor].freeze
  STATUSES = %w[pending accepting accepted rejected failed].freeze

  belongs_to :conversation
  belongs_to :decided_by, class_name: "User", optional: true
  belongs_to :reference_term, optional: true
  has_one_attached :file

  validates :source, inclusion: { in: SOURCES }
  validates :status, inclusion: { in: STATUSES }
  validates :title, presence: true
  validates :norm_code, presence: true, if: -> { source == "cal" }
  validates :reference_term, presence: true, if: -> { source == "biblioteca" }
  validates :url, presence: true, format: { with: %r{\Ahttps?://}i }, if: -> { source == "internet" }

  scope :accepted, -> { where(status: "accepted") }
  scope :open, -> { where(status: %w[pending accepting]) }

  STATUSES.each { |name| define_method(:"#{name}?") { status == name } }

  def source_label
    case source
    when "biblioteca" then "biblioteca de TRs da Papyrus (#{reference_term&.label})"
    when "cal" then "CAL/Ius Natura (#{norm_code})"
    when "internet" then "internet"
    else "arquivo enviado na conversa"
    end
  end

  # Card no chat, mesma mecânica de KnowledgeNote/ProjectIssue: mensagem assistant própria com o id.
  def announce!
    conversation.messages.create!(role: "assistant", content: { term_of_reference_candidate_id: id }.to_json)
    conversation.broadcast_refresh
  end

  def accept!(user)
    update!(status: "accepting", decided_by: user, decided_at: Time.current, error: nil)
    AcceptTermOfReferenceJob.perform_later(id)
  end

  def reject!(user)
    update!(status: "rejected", decided_by: user, decided_at: Time.current)
  end
end
