require "test_helper"

class FillClientSpreadsheetToolTest < ActiveJob::TestCase
  setup do
    @conversation = conversations(:priced_conversation)
    @tool = FillClientSpreadsheetTool.new(conversation: @conversation)
  end

  test "enfileira o preenchimento da planilha mais recente, nunca chama a IA na hora" do
    attach("Anexo 02 PPU.xlsx")

    assert_no_ai_calls do
      assert_enqueued_jobs(1, only: FillClientSpreadsheetJob) do
        response = JSON.parse(@tool.execute(orientacao: "item 3 é só offshore"))
        assert response["success"]
      end
    end
    fill = @conversation.spreadsheet_fills.last
    assert_equal "Anexo 02 PPU.xlsx", fill.source_filename
    assert_equal "item 3 é só offshore", fill.instructions
  end

  test "pedido repetido enquanto preenche não enfileira de novo" do
    attach("DFP.xlsm")
    @tool.execute

    assert_no_enqueued_jobs(only: FillClientSpreadsheetJob) { @tool.execute }
  end

  test "sem planilha anexada, ou sem precificação, explica em vez de enfileirar" do
    assert JSON.parse(@tool.execute)["error"].include?("Não encontrei planilha")

    attach("PPU.xlsx")
    without_pricing = FillClientSpreadsheetTool.new(conversation: conversations(:reviewing_conversation))
    assert JSON.parse(without_pricing.execute)["error"].include?("precificação")
  end

  private

  def attach(filename)
    message = @conversation.messages.create!(role: "user", content: "segue a planilha")
    message.attachments.attach(io: StringIO.new(client_xlsx_bytes), filename: filename)
  end
end
