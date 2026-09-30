module SpreadsheetFillsHelper
  # Último preenchimento de cada planilha da conversa, numa consulta só (a tela redesenha a cada morph).
  def latest_spreadsheet_fills(conversation)
    @latest_spreadsheet_fills ||= {}
    @latest_spreadsheet_fills[conversation.id] ||=
      conversation.spreadsheet_fills.latest_per_blob.includes(result_attachment: :blob).index_by(&:source_blob_id)
  end

  # Planilhas preenchidas pra "Gerados pela IA": a versão mais recente de cada planilha, as anteriores
  # e se tem uma nova sendo preenchida agora. Uma consulta só, com resultado e nome da original.
  SpreadsheetGroup = Data.define(:source_blob, :latest, :older, :processing)

  def spreadsheet_fill_groups(conversation)
    fills = conversation.spreadsheet_fills.where(status: %w[done processing])
      .includes(:source_blob, result_attachment: :blob).order(id: :desc).to_a
    fills.each do |fill| # preloads usados em todas (Bullet)
      fill.result.attached?
      fill.source_blob
    end
    fills.group_by(&:source_blob_id).values.map do |list|
      done = list.select { |fill| fill.done? && fill.result.attached? }
      SpreadsheetGroup.new(list.first.source_blob, done.first, done.drop(1), list.first.processing?)
    end
  end

  def client_spreadsheet_attachments(conversation)
    @client_spreadsheet_attachments ||= {}
    @client_spreadsheet_attachments[conversation.id] ||= SpreadsheetFill.client_spreadsheets(conversation)
  end

  # Só monta o catálogo (várias consultas) quando há planilha preenchida pra conferir.
  def spreadsheet_fill_stale?(conversation, fill)
    return false unless fill&.done? && conversation.proposal&.project_pricing

    @spreadsheet_catalogs ||= {}
    catalog = @spreadsheet_catalogs[conversation.id] ||= Spreadsheets::FactCatalog.new(conversation.proposal)
    fill.stale?(catalog)
  end
end
