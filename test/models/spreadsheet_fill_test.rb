require "test_helper"

# Preenchimento automático na geração da proposta: só planilha nunca vista ou desatualizada.
# Referência ("não é formulário") e falha só voltam por pedido do consultor.
class SpreadsheetFillTest < ActiveJob::TestCase
  setup do
    @conversation = conversations(:priced_conversation)
    @proposal = proposals(:priced_proposal)
    @proposal.project_pricing.recalculate!
    message = @conversation.messages.create!(role: "user", content: "planilhas")
    message.attachments.attach(io: StringIO.new(client_xlsx_bytes), filename: "PPU.xlsx")
    message.attachments.attach(io: StringIO.new("a;b"), filename: "notas.csv")
    @blob = message.attachments.find { |a| a.filename.to_s == "PPU.xlsx" }.blob
  end

  test "só .xlsx/.xlsm do usuário contam como planilha do cliente" do
    assert_equal [ "PPU.xlsx" ], SpreadsheetFill.client_spreadsheets(@conversation).map { |a| a.filename.to_s }
  end

  test "planilha nunca vista entra na fila; enquanto preenche, não duplica" do
    assert_enqueued_jobs(1, only: FillClientSpreadsheetJob) { assert_equal [ "PPU.xlsx" ], SpreadsheetFill.queue_automatic!(@conversation) }
    assert_no_enqueued_jobs(only: FillClientSpreadsheetJob) { assert_empty SpreadsheetFill.queue_automatic!(@conversation) }
  end

  test "referência e falha não voltam sozinhas" do
    %w[not_applicable failed].each do |status|
      @conversation.spreadsheet_fills.create!(source_blob: @blob, status: status)
      assert_no_enqueued_jobs(only: FillClientSpreadsheetJob) { SpreadsheetFill.queue_automatic!(@conversation) }
    end
  end

  test "preenchida volta à fila só quando os fatos que usou mudaram" do
    catalog = Spreadsheets::FactCatalog.new(@proposal)
    keys = [ "proposta.total", "papyrus.cnpj", "hoje.data" ]
    fill = @conversation.spreadsheet_fills.create!(source_blob: @blob, status: "done", facts_digest: catalog.digest(keys), report: { used_keys: keys })

    assert_not fill.stale?(catalog)
    assert_no_enqueued_jobs(only: FillClientSpreadsheetJob) { SpreadsheetFill.queue_automatic!(@conversation) }

    @proposal.project_pricing.update!(bdi: @proposal.project_pricing.bdi + 0.1)
    @proposal.project_pricing.recalculate!
    assert fill.stale?(Spreadsheets::FactCatalog.new(@proposal.reload))
    assert_enqueued_jobs(1, only: FillClientSpreadsheetJob) { SpreadsheetFill.queue_automatic!(@conversation) }
  end
end
