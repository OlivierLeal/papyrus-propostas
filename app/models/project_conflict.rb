# Uma divergência relevante entre o que dois documentos (ou um documento e a medição do sistema)
# dizem sobre a mesma coisa — seção 13 do documento de arquitetura.
#
# A regra é não escolher sozinho. Quando o TR diz 500 ha e o KMZ mede 620, o sistema não elege um
# valor: registra a divergência, mostra os dois lados com a origem de cada um e pede orientação.
#
# Conflito aberto NÃO bloqueia a geração do documento (decisão do consultor): ele entra como
# ressalva no texto, no mesmo espírito do "A confirmar com o cliente" que já existe. O que ele
# muda é que a divergência deixa de passar despercebida.
class ProjectConflict < ApplicationRecord
  belongs_to :conversation
  belongs_to :resolved_by, class_name: "User", optional: true

  has_many :project_conflict_findings, dependent: :destroy
  has_many :findings, through: :project_conflict_findings, source: :project_finding

  # client: "levar ao cliente decidir" (só faz sentido no enquadramento legal × pedido, ver
  # #legal_framing?) — ninguém decidiu ainda, e a proposta apresenta as duas alternativas pra
  # CONTRATANTE escolher. Continua decidível depois, quando o cliente responder.
  STATUSES = %w[open client resolved dismissed].freeze

  validates :field, inclusion: { in: ProjectFinding::FIELDS.keys }
  validates :summary, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :open, -> { where(status: "open") }
  scope :undecided, -> { where(status: %w[open client]) }

  def open? = status == "open"
  def client? = status == "client"
  def undecided? = open? || client?
  def resolved? = status == "resolved"

  # Legislação (CAL) × o que o cliente pediu (ET/TR), sobre licença ou estudo — pedido da Sara
  # (2026-09-29): "a legislação diz isso, o cliente diz isso, faço o quê?". Tem card, resumo e
  # texto na proposta próprios (ver Conversation#legal_framing_snapshot_text).
  def legal_framing?
    ProjectFinding::FRAMING_FIELDS.include?(field) && findings.any? { |finding| finding.source_kind == "cal" }
  end

  def field_label = ProjectFinding::FIELDS.dig(field, :label) || field

  # Resolver é decisão humana, e por isso vira um achado novo em vez de editar os existentes:
  # a autoridade da decisão fica registrada como fonte ("consultor"), e os valores divergentes
  # continuam no banco marcados como superados, auditáveis.
  def resolve!(user, value:, note: nil)
    transaction do
      replacement = conversation.project_findings.create!(
        field: field, value: value, nature: "fato", source_kind: "consultor",
        excerpt: note.presence, status: "active"
      )
      superseded_values = findings.active.map(&:value)
      findings.active.each { |finding| finding.supersede!(replacement) }
      update!(status: "resolved", resolved_by: user, resolved_at: Time.current, resolution_note: note.presence)
      conversation.replace_study_types!(superseded_values, value) if field == "tipo_estudo"
      replacement
    end
  end

  # "Levar ao cliente decidir": nada é superado e nada é decidido — a proposta sai com as duas
  # alternativas (ver Conversation#legal_framing_snapshot_text).
  def refer_to_client!(user)
    update!(status: "client", resolved_by: user, resolved_at: Time.current)
  end

  # "Não é divergência": os dois valores continuam válidos (grafias diferentes, recortes
  # diferentes). Nada é superado — só paramos de perguntar.
  def dismiss!(user)
    update!(status: "dismissed", resolved_by: user, resolved_at: Time.current)
  end

  # Texto para o snapshot do estado da proposta, que é o que faz a IA escrever a ressalva em vez
  # de escolher um dos valores por conta própria.
  def to_context_line
    values = findings.active.map { |finding| "#{finding.value} (#{finding.origin_label})" }.join(" × ")
    "- #{field_label}: #{values} — #{summary}"
  end
end
