# Uma planilha do cliente (PPU, DFP de formação de preço, lista de equipe, dados cadastrais…)
# preenchida pelo sistema a partir da proposta. A IA lê a planilha e monta o PLANO (qual fato vai em
# qual célula, como ratear os custos entre os itens do cliente); o Ruby calcula e escreve
# (Spreadsheets::PlanExecutor). O relatório guarda o que foi escrito e de onde veio.
#
# Nem toda planilha anexada é pra preencher — pode ser referência (quantitativos, coordenadas, a
# planilha de custo antiga da própria Papyrus). A IA classifica primeiro: `not_applicable` guarda o
# motivo e nunca é reprocessada sozinha (só se o consultor mandar, `forced`).
class SpreadsheetFill < ApplicationRecord
  belongs_to :conversation
  belongs_to :source_blob, class_name: "ActiveStorage::Blob"
  has_one_attached :result

  STATUSES = %w[processing done failed not_applicable].freeze
  EXTENSIONS = %w[.xlsx .xlsm].freeze

  validates :status, inclusion: { in: STATUSES }

  scope :latest_per_blob, -> { where(id: select("MAX(id)").group(:source_blob_id)) }

  def processing? = status == "processing"
  def done? = status == "done"
  def failed? = status == "failed"
  def not_applicable? = status == "not_applicable"

  def self.spreadsheet?(filename) = EXTENSIONS.include?(File.extname(filename.to_s).downcase)

  # Planilhas anexadas na conversa (setup, complementares, chat) — as que podem ser preenchidas.
  def self.client_spreadsheets(conversation)
    ActiveStorage::Attachment.includes(:blob)
      .where(record_type: "Message", record_id: conversation.messages.where(role: "user").select(:id), name: "attachments")
      .order(:id).select { |attachment| spreadsheet?(attachment.filename) }
  end

  # Preenche o que precisa ser preenchido, sem o consultor pedir (GenerateProposalDocumentTool, na
  # geração com parte comercial): planilha nunca vista, ou já preenchida com dados que mudaram.
  # Referência (`not_applicable`) e falha só voltam por pedido do consultor. Devolve os nomes.
  def self.queue_automatic!(conversation)
    # Busca de novo: a proposta em memória de quem chama pode ter o preço de antes deste turno.
    proposal = Proposal.find_by(conversation_id: conversation.id)
    return [] unless proposal&.project_pricing

    latest = conversation.spreadsheet_fills.latest_per_blob.index_by(&:source_blob_id)
    catalog = nil
    client_spreadsheets(conversation).filter_map do |attachment|
      fill = latest[attachment.blob_id]
      next if fill && !fill.done?
      next if fill && !fill.stale?(catalog ||= Spreadsheets::FactCatalog.new(proposal))

      conversation.spreadsheet_fills.create!(source_blob: attachment.blob, automatic: true).tap { |f| FillClientSpreadsheetJob.perform_later(f.id) }
      attachment.filename.to_s
    end
  end

  def source_filename = source_blob.filename.to_s

  def result_filename
    "#{source_blob.filename.base}_Papyrus.#{source_blob.filename.extension}"
  end

  # Os fatos que este preenchimento usou mudaram desde então (preço, equipe, horas…).
  def stale?(catalog)
    done? && facts_digest.present? && facts_digest != catalog.digest(used_keys)
  end

  def entries = Array(report["entries"])
  def warnings = Array(report["warnings"])
  def issues = Array(report["issues"])
  def totals = report["totals"]
  def used_keys = Array(report["used_keys"])
  def reason = report["reason"]
end
