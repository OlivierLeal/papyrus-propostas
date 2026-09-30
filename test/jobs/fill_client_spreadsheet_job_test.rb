require "test_helper"

class FillClientSpreadsheetJobTest < ActiveJob::TestCase
  setup do
    @conversation = conversations(:priced_conversation)
    @proposal = proposals(:priced_proposal)
    @proposal.project_pricing.recalculate!
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(client_xlsx_bytes), filename: "PPU Cliente.xlsx")
    @fill = @conversation.spreadsheet_fills.create!(source_blob: blob)
    @pieces = Spreadsheets::FactCatalog.new(@proposal).pieces.map(&:key)
  end

  test "preenche pelo plano da IA, guarda o relatório, posta o card e transforma dúvida em pendência" do
    plan = {
      "celulas" => [ { "aba" => "PPU", "celula" => "A1", "fato" => "papyrus.razao_social" } ],
      "precos_unitarios" => [ { "aba" => "PPU", "celula" => "F3", "quantidade_celula" => "E3",
                                "composicao" => @pieces.map { |key| { "peca" => key, "fracao" => 1 } } } ],
      "duvidas" => [ "A PPU pede 2.994 diárias e a proposta tem 600. Qual vale?" ]
    }

    with_recalculator(nil) do
      stub_ai_complete("```json\n#{plan.to_json}\n```") { FillClientSpreadsheetJob.perform_now(@fill.id) }
    end

    @fill.reload
    assert @fill.done?, @fill.error
    assert @fill.result.attached?
    assert_equal "PPU Cliente_Papyrus.xlsx", @fill.result.filename.to_s
    assert_equal @fill.totals["proposta"], @fill.totals["planilha"]
    issue = @conversation.project_issues.find_by(source: "planilha")
    assert issue&.open?, "dúvida da planilha trava a geração como qualquer pendência"
    cards = @conversation.messages.where(role: "assistant").pluck(:content)
    assert_includes cards, { spreadsheet_fill_id: @fill.id }.to_json
  end

  test "total recalculado diferente do da proposta: devolve à IA pra corrigir o plano" do
    wrong = { "precos_unitarios" => [ { "aba" => "PPU", "celula" => "F3", "quantidade" => 1, "composicao" => [] } ],
              "celula_total" => { "aba" => "PPU", "celula" => "G5" } }
    right = wrong.merge("precos_unitarios" => [ { "aba" => "PPU", "celula" => "F3", "quantidade_celula" => "E3",
                                                   "composicao" => @pieces.map { |key| { "peca" => key, "fracao" => 1 } } } ])
    target = Spreadsheets::FactCatalog.new(@proposal)["proposta.total"].value.round(2)
    recalculated = [ 0, target ].map { |total| fake_recalculated(total) }

    with_recalculator(-> { recalculated.shift }) do
      stub_ai_complete([ wrong.to_json, right.to_json ]) { FillClientSpreadsheetJob.perform_now(@fill.id) }
    end

    @fill.reload
    assert_equal target.to_f, @fill.totals["planilha"]
    assert @conversation.messages.where(internal: true, role: "user").where("content LIKE ?", "CONFERÊNCIA%").exists?
  end

  test "planilha de referência: não preenche; automático fica só no painel, pedido vira card" do
    reference = { preencher: false, motivo: "Lista de coordenadas dos poços." }.to_json
    @fill.update!(automatic: true)
    stub_ai_complete(reference) { FillClientSpreadsheetJob.perform_now(@fill.id) }

    assert @fill.reload.not_applicable?
    assert_equal "Lista de coordenadas dos poços.", @fill.reason
    assert_not @fill.result.attached?
    assert_not @conversation.messages.where(content: { spreadsheet_fill_id: @fill.id }.to_json).exists?

    manual = @conversation.spreadsheet_fills.create!(source_blob: @fill.source_blob)
    stub_ai_complete(reference) { FillClientSpreadsheetJob.perform_now(manual.id) }
    assert @conversation.messages.where(content: { spreadsheet_fill_id: manual.id }.to_json).exists?
  end

  test "consultor mandou preencher mesmo assim: o prompt diz isso e o 'não' da IA não vale" do
    forced = @conversation.spreadsheet_fills.create!(source_blob: @fill.source_blob, forced: true)
    plan = { preencher: false, motivo: "parece referência", tipo_planilha: "formulario",
             celulas: [ { aba: "PPU", celula: "A1", fato: "papyrus.razao_social" } ] }

    stub_ai_complete(plan.to_json) { FillClientSpreadsheetJob.perform_now(forced.id) }

    assert forced.reload.done?
    assert @conversation.messages.where("content LIKE ?", "%CONSULTOR CONFIRMOU%").exists?
    assert_empty forced.issues, "formulário que não é de preço não cobra cobertura do custo"
    assert_includes forced.used_keys, "papyrus.razao_social"
    assert forced.facts_digest.present?
  end

  test "resposta cortada da IA ganha uma nova tentativa antes de falhar" do
    plan = { preencher: true, tipo_planilha: "formulario", celulas: [ { aba: "PPU", celula: "A1", fato: "papyrus.razao_social" } ] }
    stub_ai_complete([ '{"preencher": true, "celulas": [{"aba": "PPU"', plan.to_json ]) { FillClientSpreadsheetJob.perform_now(@fill.id) }

    assert @fill.reload.done?
  end

  test "resposta ilegível da IA: falha com card, sem arquivo" do
    stub_ai_complete("não sei") { FillClientSpreadsheetJob.perform_now(@fill.id) }

    assert @fill.reload.failed?
    assert_not @fill.result.attached?
  end

  private

  def fake_recalculated(total)
    Struct.new(:total) do
      def value(_sheet, _ref) = total
      def to_prompt_text(**) = "PPU!G5 → #{total}"
    end.new(total)
  end

  def with_recalculator(result)
    original = Spreadsheets::Recalculator.method(:call)
    Spreadsheets::Recalculator.define_singleton_method(:call) { |*| result.respond_to?(:call) ? result.call : result }
    yield
  ensure
    Spreadsheets::Recalculator.define_singleton_method(:call, original)
  end
end

class SpreadsheetFillCardTest < ActionDispatch::IntegrationTest
  test "o card mostra total conferido, o que conferir, a origem de cada célula e o download" do
    sign_in_as users(:one)
    conversation = conversations(:priced_conversation)
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(client_xlsx_bytes), filename: "PPU.xlsx")
    fill = conversation.spreadsheet_fills.create!(source_blob: blob, status: "done", report: {
      entries: [ { aba: "PPU", celula: "F3", valor: "80,11", origem: "Diária embarcada: (L1) × BDI e impostos ÷ 100" } ],
      warnings: [ "Rateio de Fulano somava 90%; ajustado pra 100%." ], issues: [ "Falta informar: Sindicato" ],
      totals: { planilha: 1000.0, proposta: 1000.0 }
    })
    fill.result.attach(io: StringIO.new(client_xlsx_bytes), filename: "PPU_Papyrus.xlsx")
    conversation.messages.create!(role: "assistant", content: { spreadsheet_fill_id: fill.id }.to_json)

    get conversation_path(conversation)

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(fill)}" do
      assert_select "p.text-success", text: /igual ao total da proposta/
      assert_select "li", text: "Falta informar: Sindicato"
      assert_select "td", text: /BDI e impostos ÷ 100/
      assert_select "a", text: "Baixar"
    end
  end
end
