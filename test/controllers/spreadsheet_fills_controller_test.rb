require "test_helper"

class SpreadsheetFillsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    sign_in_as users(:one)
    @conversation = conversations(:priced_conversation)
    message = @conversation.messages.create!(role: "user", content: "planilha")
    message.attachments.attach(io: StringIO.new(client_xlsx_bytes), filename: "PPU.xlsx")
    @attachment = message.attachments.first
  end

  test "botão Preencher enfileira; aba Arquivos e Tela de Precificação mostram a planilha com o botão" do
    get conversation_path(@conversation)
    assert_select "#spreadsheet_status_#{@attachment.id} button", text: /Preencher/

    get conversation_proposal_path(@conversation)
    assert_select "#generated_documents h2", text: /Gerados pela IA/
    assert_select "#spreadsheet_waiting_#{@attachment.id} button", text: "Preencher"

    assert_enqueued_jobs(1, only: FillClientSpreadsheetJob) do
      post conversation_spreadsheet_fills_path(@conversation), params: { attachment_id: @attachment.id }
    end
    assert_redirected_to conversation_path(@conversation)
    assert_not @conversation.spreadsheet_fills.last.automatic?
  end

  test "planilha classificada como referência: o consultor manda preencher mesmo assim" do
    @conversation.spreadsheet_fills.create!(source_blob: @attachment.blob, status: "not_applicable", report: { reason: "Coordenadas dos poços." })

    get conversation_path(@conversation)
    assert_select "#spreadsheet_status_#{@attachment.id}", text: /Coordenadas dos poços/
    assert_select "#spreadsheet_status_#{@attachment.id} button", text: /Preencher mesmo assim/

    post conversation_spreadsheet_fills_path(@conversation), params: { attachment_id: @attachment.id }
    assert @conversation.spreadsheet_fills.last.forced?
  end

  test "Gerados pela IA: planilha preenchida com a atual, as anteriores e o selo de desatualizada" do
    old = @conversation.spreadsheet_fills.create!(source_blob: @attachment.blob, status: "done", report: { used_keys: [] })
    old.result.attach(io: StringIO.new(client_xlsx_bytes), filename: "PPU_Papyrus_v1.xlsx")
    fill = @conversation.spreadsheet_fills.create!(source_blob: @attachment.blob, status: "done", facts_digest: "outro",
      report: { used_keys: [ "proposta.total" ], totals: { planilha: 10, proposta: 10 } })
    fill.result.attach(io: StringIO.new(client_xlsx_bytes), filename: "PPU_Papyrus.xlsx")

    [ conversation_path(@conversation), conversation_proposal_path(@conversation) ].each do |path|
      get path
      assert_select "#spreadsheet_group_#{@attachment.blob_id}" do
        assert_select "a[title='Baixar PPU_Papyrus.xlsx']"
        assert_select "span", text: "Desatualizada"
        assert_select ".badge", text: "Total = proposta"
        assert_select "details", text: /Versões anteriores \(1\)/
        assert_select "button", text: /Preencher de novo/
      end
    end
    get conversation_path(@conversation)
    assert_select "#spreadsheet_status_#{@attachment.id}", text: /Gerados pela IA/
  end
end
