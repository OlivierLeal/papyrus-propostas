# Uma informação sobre o projeto desta conversa, com a origem junto (documento e trecho) e a
# natureza declarada (fato, inferência ou sugestão).
#
# Antes disto, o "entendimento do projeto" só existia como JSON solto dentro das mensagens do
# assistente, reparseado a cada uso (GenerateSummaryJob#extracted_fields, hoje removido). Isso
# funcionava para montar um resumo, mas não respondia a pergunta que importa — "por que você
# concluiu isso?" — e não dava como comparar o que dois documentos dizem sobre a mesma coisa.
#
# O `field` é menu fechado pelo mesmo motivo que o tipo de estudo e a equipe são: chave inventada
# pela IA não agrupa com nada e não compara com nada. O que não couber no menu entra como "outro",
# preservado no valor, em vez de sumir.
class ProjectFinding < ApplicationRecord
  belongs_to :conversation
  belongs_to :source_blob, class_name: "ActiveStorage::Blob", optional: true
  belongs_to :superseded_by, class_name: "ProjectFinding", optional: true

  has_many :project_conflict_findings, dependent: :destroy
  has_many :project_conflicts, through: :project_conflict_findings

  # comparable: entra na detecção de divergência entre documentos. Lista acumulativa fica de
  # fora de propósito — diagnóstico que aparece num documento e não no outro é complemento, não
  # contradição. numeric: comparado por tolerância, sem IA.
  FIELDS = {
    "tipo_licenca" => { label: "Tipo de licença", comparable: true },
    "tipo_estudo" => { label: "Tipo de estudo", comparable: true },
    "orgao_ambiental" => { label: "Órgão ambiental", comparable: true },
    "municipios" => { label: "Municípios", comparable: true },
    "empreendimento" => { label: "Empreendimento", comparable: true },
    "area_ha" => { label: "Área (ha)", comparable: true, numeric: true },
    "perimetro_km" => { label: "Perímetro (km)", comparable: true, numeric: true },
    "prazo" => { label: "Prazo", comparable: true },
    "diagnosticos" => { label: "Diagnósticos", comparable: false },
    "condicionantes" => { label: "Condicionantes", comparable: false },
    "ressalvas" => { label: "Ressalvas", comparable: false },
    "produtos" => { label: "Produtos/entregáveis", comparable: false },
    "outro" => { label: "Outra informação", comparable: false }
  }.freeze

  NATURES = {
    "fato" => "Fato",
    "inferencia" => "Inferência",
    "sugestao" => "Sugestão"
  }.freeze

  # A ordem aqui é a autoridade da fonte (seção 7 do documento de arquitetura): decisão do
  # consultor vence tudo; o que o sistema mediu (área/perímetro do KMZ) vence o que um documento
  # afirma; TR vence complementar. Ordena o que o consultor vê ao decidir uma divergência — nunca
  # resolve a divergência sozinha.
  SOURCE_KINDS = {
    "consultor" => "Decisão do consultor",
    "sistema" => "Calculado pelo sistema",
    "tr" => "Termo de Referência",
    "complementar" => "Documento complementar"
  }.freeze

  STATUSES = %w[active superseded].freeze

  EXCERPT_LIMIT = 300

  validates :field, inclusion: { in: FIELDS.keys }
  validates :nature, inclusion: { in: NATURES.keys }
  validates :source_kind, inclusion: { in: SOURCE_KINDS.keys }
  validates :status, inclusion: { in: STATUSES }
  validates :value, presence: true

  scope :active, -> { where(status: "active") }
  scope :comparable, -> { where(field: FIELDS.select { |_, config| config[:comparable] }.keys) }

  def field_label = FIELDS.dig(field, :label) || field
  def nature_label = NATURES.fetch(nature, nature)
  def source_label = SOURCE_KINDS.fetch(source_kind, source_kind)

  def numeric_field? = FIELDS.dig(field, :numeric).present?

  # Código de citação usado pela IA no texto do chat ("[F12]") e resolvido de volta para o chip
  # com o trecho de origem — ver ApplicationHelper#render_markdown.
  def citation_code = "F#{id}"

  def document_name = source_blob&.filename&.to_s

  # Linha curta de origem, para o card de conflito e para o popover da citação.
  def origin_label
    [ source_label, document_name, locator.presence ].compact_blank.join(" · ")
  end

  # O que a IA enxerga da lista de achados. O trecho NÃO entra: repeti-lo a cada turno do chat
  # custaria contexto para algo que só o consultor precisa ver, e ele vê no chip.
  def to_context_line
    "- [#{citation_code}] #{field_label}: #{value} (#{nature_label}, #{origin_label})"
  end

  def supersede!(replacement)
    update!(status: "superseded", superseded_by: replacement)
  end
end
