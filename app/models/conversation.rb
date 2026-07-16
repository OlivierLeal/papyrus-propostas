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

  belongs_to :user
  belongs_to :study_type
  has_one :geospatial_result, dependent: :destroy

  validates :client_name, presence: true
  validates :status, inclusion: { in: STATUSES }

  def status_label
    STATUS_LABELS.fetch(status, status)
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
