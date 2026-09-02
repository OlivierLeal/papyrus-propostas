# Conhecimento capturado durante uma conversa e guardado para as PRÓXIMAS propostas
# (CLAUDE.md seção 11.1, item 4 — "memória por cliente").
#
# Diferente do acervo histórico, que é material humano já existente em disco, uma nota nasce de
# algo que apareceu no chat: uma exigência do cliente, uma decisão de escopo, uma condicionante
# do órgão, ou uma correção que o consultor fez na IA.
#
# Por isso ela nasce PENDENTE. O acervo é confiável porque tudo nele foi escrito e assinado por
# gente; deixar a IA gravar direto o que "achou interessante" faria a inferência dela voltar
# meses depois com a mesma autoridade de uma proposta real — e citada como
# "acervo Papyrus", o que faz uma invenção parecer verificável. Quem promove a nota a
# conhecimento consultável é o consultor.
class KnowledgeNote < ApplicationRecord
  # Nasce de uma proposta (conversation) OU do chat geral de dúvidas (general_chat, sem proposta
  # nenhuma) — nunca das duas. GenerateSummaryJob busca por client_name direto na tabela toda
  # (não por conversation.knowledge_notes), então uma nota nascida no chat geral já reaparece
  # sozinha em propostas futuras do mesmo cliente, sem precisar de nenhuma outra mudança.
  belongs_to :conversation, optional: true
  belongs_to :general_chat, optional: true
  belongs_to :approved_by, class_name: "User", optional: true

  validate :belongs_to_exactly_one_origin

  has_neighbors :embedding

  CATEGORIES = {
    "preferencia_cliente" => "Preferência ou exigência recorrente do cliente",
    "escopo_metodologia" => "Decisão de escopo ou metodologia que vale repetir",
    "condicionante_orgao" => "Condicionante ou ressalva do órgão ambiental",
    "correcao_consultor" => "Correção que o consultor fez e a IA deve lembrar"
  }.freeze

  # Rótulos curtos para a citação: o label completo é descritivo demais para caber numa frase
  # ("memória da Papyrus: correção que o consultor fez e a IA deve lembrar · Petrobras").
  REFERENCE_LABELS = {
    "preferencia_cliente" => "preferência do cliente",
    "escopo_metodologia" => "decisão de escopo",
    "condicionante_orgao" => "condicionante do órgão",
    "correcao_consultor" => "correção do consultor"
  }.freeze

  STATUSES = %w[pending approved rejected].freeze

  validates :content, presence: true
  validates :category, inclusion: { in: CATEGORIES.keys }
  validates :status, inclusion: { in: STATUSES }

  scope :pending, -> { where(status: "pending") }
  scope :approved, -> { where(status: "approved") }
  # Só nota aprovada E com vetor participa da busca.
  scope :searchable, -> { approved.where.not(embedded_at: nil) }

  def pending? = status == "pending"
  def approved? = status == "approved"

  def category_label = CATEGORIES.fetch(category, category)

  # Aprovar e embedar andam juntos: uma nota aprovada sem vetor não é encontrável, o que na
  # prática equivale a não ter sido aprovada.
  def approve!(user)
    transaction do
      update!(status: "approved", approved_by: user, approved_at: Time.current)
      embed!
    end
  end

  def reject!(user)
    update!(status: "rejected", approved_by: user, approved_at: Time.current)
  end

  def embed!
    vector = Rag::Embedder.new.embed_documents([ searchable_text ]).first
    update_columns(embedding: vector, embedding_model: Rag::Embedder::MODEL_ID, embedded_at: Time.current)
  end

  # A categoria e o cliente entram no texto embedado: sem isso, "exigência da Petrobras sobre
  # equipe" não casa com uma nota cujo conteúdo nunca repete o nome do cliente.
  def searchable_text
    [ category_label, client_name, content ].compact_blank.join(" — ")
  end

  # Origem sempre explícita ao devolver para a IA — mesma regra do acervo.
  def reference
    quando = approved_at&.strftime("%m/%Y")
    "memória da Papyrus: #{REFERENCE_LABELS.fetch(category, category)}#{" · #{client_name}" if client_name.present?}" \
    "#{" (#{quando})" if quando}"
  end

  private
    def belongs_to_exactly_one_origin
      errors.add(:base, "precisa vir de uma conversation ou de um general_chat, nunca dos dois") if conversation.present? == general_chat.present?
    end
end
