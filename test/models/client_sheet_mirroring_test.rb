require "test_helper"

# Precificação espelhando a lista de preços do cliente (2026-09-30, conversa 65: a PPU pedia 2.994
# diárias embarcadas, a equipe estimada pelo escopo tinha 600 e a diária saiu a R$ 71).
class ClientSheetMirroringTest < ActiveJob::TestCase
  setup do
    @proposal = proposals(:priced_proposal)
    @conversation = @proposal.conversation
    @pricing = @proposal.project_pricing
    message = @conversation.messages.create!(role: "user", content: "PPU")
    message.attachments.attach(io: StringIO.new(client_xlsx_bytes), filename: "Anexo 02 PPU.xlsx")
    @blob = message.attachments.first.blob
    @biologa = professionals(:biologa)
  end

  def suggestion
    { "itens" => [
      { "nome" => "Diária embarcada", "planilha" => { "blob_id" => @blob.id, "aba" => "PPU", "codigo" => "1.1", "unidade" => "diária",
                                                      "celula_preco" => "F3", "celula_quantidade" => "E3" },
        "equipe" => [ { "professional_id" => @biologa.id, "deliverable_name" => "Observadora", "man_hours_por_unidade" => 0, "field_days_por_unidade" => 0.5 } ],
        "custos" => [ { "descricao" => "Passagem por troca de turma", "quantidade_por_unidade" => 0.1 } ] },
      { "nome" => "Relatório por poço", "planilha" => { "blob_id" => @blob.id, "aba" => "PPU", "codigo" => "2.1", "unidade" => "relatório",
                                                        "celula_preco" => "F4", "celula_quantidade" => "E4" },
        "equipe" => [ { "professional_id" => @biologa.id, "deliverable_name" => "Relatório", "man_hours_por_unidade" => 40, "field_days_por_unidade" => 0 } ] }
    ] }
  end

  test "o prompt de equipe recebe a lista de preços do cliente" do
    prompt = stub_class_method(Rag::PrecedentFinder, :new, ->(*) { raise "sem acervo" }) { @proposal.send(:team_suggestion_prompt) }

    assert_includes prompt, "LISTA DE PREÇOS DO CLIENTE"
    assert_includes prompt, "Anexo 02 PPU.xlsx"
    assert_includes prompt, "man_hours_por_unidade"
  end

  test "item espelhado: quantidade lida da CÉLULA, esforço por unidade × quantidade, custos por unidade" do
    @proposal.send(:apply_team_suggestion!, @pricing, suggestion)

    item = @pricing.pricing_items.reload.find_by(client_code: "1.1")
    assert_equal 100, item.client_quantity # E3 da planilha, não da IA
    assert_equal "Item 1.1 · 100 diária", item.client_label
    line = item.proposal_professionals.find_by(professional: @biologa)
    assert_equal [ 0.5, 50 ], [ line.field_days_per_unit.to_f, line.field_days.to_f ]
    assert_equal [ { "description" => "Passagem por troca de turma", "quantity" => 10.0, "unit_value" => 0.0 } ], item.costs

    item.update!(client_quantity: 200)
    assert_equal 100, line.reload.field_days, "mudar a quantidade do cliente refaz o total da equipe"
  end

  test "editar só o total numa linha espelhada recalcula o por-unidade" do
    @proposal.send(:apply_team_suggestion!, @pricing, suggestion)
    line = @pricing.pricing_items.reload.find_by(client_code: "2.1").proposal_professionals.first

    line.update!(man_hours: 150)
    assert_equal 50, line.man_hours_per_unit # 150 ÷ 3 relatórios
  end

  test "reorganizar só troca a precificação quando a IA devolve itens da planilha" do
    old_lines = @pricing.proposal_professionals.count
    stub_ai_complete('{"itens": [{"nome": "Sem planilha", "equipe": []}]}') do
      assert_equal :failed, @proposal.rebuild_team_from_client_sheet!
    end
    assert_equal old_lines, @pricing.proposal_professionals.count, "falha da IA não apaga nada"

    stub_ai_complete(suggestion.to_json) { assert_equal :done, @proposal.rebuild_team_from_client_sheet! }
    assert_equal %w[1.1 2.1], @pricing.pricing_items.reload.filter_map(&:client_code).sort
  end

  test "PPU de itens espelhados: preço unitário = custo do item ÷ quantidade, comuns rateados, total = proposta" do
    @proposal.send(:apply_team_suggestion!, @pricing, suggestion)
    @pricing.pricing_items.find_by(client_code: "1.1").update!(costs: [ { "description" => "Passagem", "quantity" => 10, "unit_value" => 500 } ])
    @pricing.recalculate!
    fill = @conversation.spreadsheet_fills.create!(source_blob: @blob)

    with_recalculator(nil) do
      stub_ai_complete({ preencher: true, celulas: [ { aba: "PPU", celula: "A1", fato: "papyrus.razao_social" } ],
                         precos_unitarios: [ { aba: "PPU", celula: "F3", quantidade: 1, composicao: [] } ] }.to_json) do
        FillClientSpreadsheetJob.perform_now(fill.id)
      end
    end

    fill.reload
    assert fill.done?, fill.error
    workbook = Spreadsheets::Workbook.open(fill.result.download)
    total = 100 * workbook.value("PPU", "F3").to_d + 3 * workbook.value("PPU", "F4").to_d
    assert_in_delta @pricing.reload.total_value.to_f, total.to_f, 0.03
    assert_empty fill.issues
    diaria = fill.entries.find { |entry| entry["celula"] == "F3" }
    assert_match(/1\.1 Diária embarcada/, diaria["origem"])
  end

  private

  def with_recalculator(result)
    original = Spreadsheets::Recalculator.method(:call)
    Spreadsheets::Recalculator.define_singleton_method(:call) { |*| result }
    yield
  ensure
    Spreadsheets::Recalculator.define_singleton_method(:call, original)
  end
end
