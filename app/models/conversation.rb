class Conversation < ApplicationRecord
  acts_as_chat

  STATUSES = %w[setup processing reviewing pricing completed].freeze

  STATUS_LABELS = {
    "setup" => "Configuração",
    "processing" => "Processando",
    "reviewing" => "Em revisão",
    "pricing" => "Precificação",
    "completed" => "Concluída"
  }.freeze

  # Etapas de processamento em background disparadas ao confirmar o setup.
  # "summary" roda depois que as etapas abaixo terminam (done/skipped/failed).
  # KMZ/geoespacial ainda não entra aqui — ver GeospatialResult (pendente).
  PROCESSING_STEPS = %w[tr comp_docs].freeze

  PROCESSING_STEP_LABELS = {
    "tr" => "Processando TR",
    "comp_docs" => "Analisando documentos complementares",
    "summary" => "Gerando resumo"
  }.freeze

  # Prompt de sistema (CLAUDE.md seção 9, "Prompt 1"). Mantém a IA restrita ao escopo desta
  # proposta — sem isso ela responde qualquer pergunta fora de contexto e gasta tokens à toa.
  SYSTEM_INSTRUCTIONS = <<~TEXT.freeze
    Você é o assistente de IA integrado ao Papyrus Propostas, usado por um consultor da Papyrus
    Consultoria Ambiental para montar a proposta técnica e comercial desta conversa.

    Seu escopo aqui é estritamente:
    - Analisar o Termo de Referência (TR), o KMZ e os documentos complementares desta proposta.
    - Responder perguntas do consultor sobre o conteúdo desses documentos, o escopo do estudo, a
      equipe técnica sugerida e questões de licenciamento ambiental relacionadas a este projeto.
    - Ajudar a ajustar o resumo da proposta conforme o consultor pedir.

    Qualquer pedido fora desse escopo (perguntas sem relação com este projeto ou com licenciamento
    ambiental, código, receitas, tarefas genéricas ou qualquer assunto alheio a este atendimento):
    recuse em UMA frase curta, sem elaborar, redirecionando o consultor de volta para a proposta.

    Você nunca calcula preços, horas ou valores em R$ — isso é feito por um motor determinístico à
    parte. Sua função é só identificar e organizar informações de escopo. Responda sempre em português.
  TEXT

  belongs_to :user
  belongs_to :study_type
  has_one :geospatial_result, dependent: :destroy
  has_one :proposal, dependent: :destroy

  validates :client_name, presence: true
  validates :status, inclusion: { in: STATUSES }

  def status_label
    STATUS_LABELS.fetch(status, status)
  end

  def apply_system_instructions!
    with_instructions(SYSTEM_INSTRUCTIONS)
    messages.where(role: "system").find_each { |message| message.update!(internal: true) }
  end

  def attachments_of_kind(kind)
    messages.flat_map(&:attachments).select { |attachment| attachment.blob.metadata["kind"] == kind.to_s }
  end

  def attachment_of_kind(kind)
    attachments_of_kind(kind).first
  end

  def processing_step_status(step)
    processing_steps[step.to_s] || "pending"
  end

  def processing_step_label(step)
    PROCESSING_STEP_LABELS.fetch(step.to_s, step.to_s)
  end

  # Manda uma pergunta pra IA sem expor a instrução (prompt de sistema do job/controller) na
  # conversa que o consultor vê — só a resposta da IA aparece na tela de revisão/chat.
  # hide_response: true também esconde a resposta da IA do chat (ex.: extrações em JSON que não
  # são pra consultor ler) — por padrão só a instrução fica escondida, porque GenerateSummaryJob
  # depende de ask_internally pra gerar o resumo que o consultor DEVE ver na tela de revisão.
  def ask_internally(prompt, with: nil, hide_response: false)
    instruction = create_user_message(prompt, with: with)
    instruction.update!(internal: true)
    complete
    messages.where(role: "assistant").order(:created_at).last&.update!(internal: true) if hide_response
  end

  # Usa o operador jsonb `||` do Postgres pra fazer o merge no banco (atômico),
  # em vez de merge em Ruby sobre o hash em memória — necessário porque os jobs
  # (tr/comp_docs) rodam em paralelo de verdade via Solid Queue, e um merge em
  # Ruby baseado em snapshot desatualizado perde a escrita de outro job (last-write-wins).
  def mark_step!(step, status)
    merge_processing_steps!(step.to_s => status)
    reload
    broadcast_replace_to self, target: "processing_status", partial: "conversations/processing_status", locals: { conversation: self }
  end

  # Chamado ao final de cada job de processamento; dispara o GenerateSummaryJob
  # assim que tr/comp_docs estiverem todos resolvidos (done/skipped/failed).
  # O update_all condicional evita disparar o resumo duas vezes se dois jobs terminarem ao mesmo tempo.
  def check_processing_complete!
    return unless PROCESSING_STEPS.all? { |step| %w[done skipped failed].include?(processing_step_status(step)) }

    guarded_update = self.class.where(id: id)
                         .where("processing_steps ->> 'summary' = ?", "pending")
                         .update_all([ "processing_steps = processing_steps || ?::jsonb", { "summary" => "queued" }.to_json ])
    return unless guarded_update.positive?

    GenerateSummaryJob.perform_later(id)
  end

  private
    def merge_processing_steps!(patch)
      self.class.where(id: id).update_all([ "processing_steps = processing_steps || ?::jsonb", patch.to_json ])
    end
end
