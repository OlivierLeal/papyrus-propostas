# Uma divergência relevante entre o que dois documentos (ou um documento e a medição do sistema)
# dizem sobre a mesma coisa — seção 13 do documento de arquitetura.
#
# A regra é não escolher sozinho. Quando o TR diz 500 ha e o KMZ mede 620, o sistema não elege um
# valor: registra a divergência, mostra os dois lados com a origem de cada um e pede orientação.
#
# Conflito aberto TRAVA a geração do documento desde 2026-09-30 (antes só virava ressalva, e o
# consultor pulava a decisão — conversa 65). Decidir, marcar "não é divergência", levar ao cliente
# (enquadramento legal) ou "seguir sem decidir" com motivo liberam; nos dois últimos o texto sai
# com a ressalva cobrindo os dois cenários.
class ProjectConflict < ApplicationRecord
  belongs_to :conversation
  belongs_to :resolved_by, class_name: "User", optional: true

  has_many :project_conflict_findings, dependent: :destroy
  has_many :findings, through: :project_conflict_findings, source: :project_finding

  # client: "levar ao cliente decidir" (só faz sentido no enquadramento legal × pedido, ver
  # #legal_framing?) — ninguém decidiu ainda, e a proposta apresenta as duas alternativas pra
  # CONTRATANTE escolher. Continua decidível depois, quando o cliente responder.
  # waived: "seguir sem decidir" (2026-09-30) — divergência aberta passou a TRAVAR a geração
  # (Conversation#generation_blockers); o consultor pode liberar sem escolher um lado, com motivo
  # (resolution_note), e a proposta sai com a ressalva cobrindo os dois cenários.
  STATUSES = %w[open client waived resolved dismissed].freeze

  validates :field, inclusion: { in: ProjectFinding::FIELDS.keys }
  validates :summary, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :open, -> { where(status: "open") }
  scope :undecided, -> { where(status: %w[open client]) }

  def open? = status == "open"
  def client? = status == "client"
  def undecided? = open? || client?
  def resolved? = status == "resolved"
  def waived? = status == "waived"

  def waive!(user, reason)
    return false if reason.to_s.strip.blank?

    update!(status: "waived", resolved_by: user, resolved_at: Time.current, resolution_note: reason.to_s.strip)
  end

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
      active = findings.active.to_a
      legal_values = active.select { |finding| finding.source_kind == "cal" }.map(&:value)
      rejected_legislation = legal_framing? && legal_values.none? { |legal| same_value?(legal, value) }
      active.each { |finding| finding.supersede!(replacement) }
      update!(status: "resolved", resolved_by: user, resolved_at: Time.current, resolution_note: note.presence)
      if field == "tipo_estudo"
        # Decisão em texto livre ("considere só o escopo da proposta do fornecedor") não casa com o
        # catálogo: aí só sai o que veio da legislação, e o estudo pedido pelo cliente fica.
        discarded = StudyType.match_ai_value(value) ? active.map(&:value) : legal_values
        conversation.replace_study_types!(discarded, value)
      end
      drop_legal_framing!(replacement) if rejected_legislation
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

  private
    # Conversa 79 (2026-10-16): o CAL enquadrou a mineração em LP+LI+LO/EIA, o pedido era só
    # monitoramento da qualidade do ar. A consultora decidiu o estudo contra a legislação, mas a
    # licença do CAL (que não tinha divergência própria — o ET não pede licença) continuou valendo e
    # o arquivo saiu "LP+LI+LO" em todas as revisões. Rejeitar a legislação num campo de
    # enquadramento rejeita o enquadramento inteiro: os outros achados de licença/estudo do CAL saem.
    def drop_legal_framing!(replacement)
      conversation.project_findings.active
        .where(source_kind: "cal", field: ProjectFinding::FRAMING_FIELDS - [ field ])
        .find_each { |finding| finding.supersede!(replacement) }
    end

    def same_value?(left, right)
      normalize = ->(text) { I18n.transliterate(text.to_s).downcase.gsub(/[^a-z0-9+]/, "") }
      normalize.(left) == normalize.(right)
    end
end
