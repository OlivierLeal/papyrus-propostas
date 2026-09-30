# Pendência que TRAVA a geração da proposta até o consultor responder ou liberar com justificativa
# (2026-09-30, pedido do consultor: "meu cliente tá pulando questionamentos que a IA faz e pedindo
# pra gerar direto" — conversa 65: três divergências e as dúvidas de diárias/escala sem resposta, e
# a proposta saiu com tudo "A confirmar").
#
# A trava já existiu como instrução no PROMPT e foi tirada porque a IA inventava bloqueio (equipe
# 0h, logística zerada — ver CLAUDE.md seção 13). Agora é dado: a IA só PROPÕE a pendência (no
# resumo ou pelo chat), o card mostra, e quem trava é o código (Conversation#generation_blockers).
# Nunca trava pra sempre: "Seguir sem resposta" libera, exigindo o motivo, que fica registrado e
# vira ressalva no texto.
class ProjectIssue < ApplicationRecord
  belongs_to :conversation
  belongs_to :resolved_by, class_name: "User", optional: true

  STATUSES = %w[open answered waived].freeze
  SOURCES = %w[resumo chat planilha].freeze

  validates :question, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :source, inclusion: { in: SOURCES }

  scope :open, -> { where(status: "open") }
  scope :closed, -> { where.not(status: "open") }

  def open? = status == "open"
  def answered? = status == "answered"
  def waived? = status == "waived"

  def answer!(user, text)
    return false if text.to_s.strip.blank?

    update!(status: "answered", answer: text.to_s.strip, resolved_by: user, resolved_at: Time.current)
  end

  def waive!(user, reason)
    return false if reason.to_s.strip.blank?

    update!(status: "waived", waiver_reason: reason.to_s.strip, resolved_by: user, resolved_at: Time.current)
  end

  def to_context_line
    case status
    when "answered" then "- #{question} → RESPOSTA DO CONSULTOR: #{answer}"
    when "waived" then "- #{question} → SEM RESPOSTA, liberado pelo consultor (motivo: #{waiver_reason})"
    else "- ##{id} #{question}#{" (impacto: #{impact})" if impact.present?}"
    end
  end
end
