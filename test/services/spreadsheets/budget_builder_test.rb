require "test_helper"

# Conversa 79 (2026-10-16): "gere uma planilha do zero"; a consultora queria ver HH, BDI e impostos e
# poder mudar o BDI na própria planilha.
class Spreadsheets::BudgetBuilderTest < ActiveSupport::TestCase
  setup do
    @proposal = proposals(:priced_proposal)
    @pricing = @proposal.project_pricing
    @pricing.update!(external_costs: [ { "description" => "Laboratório", "value" => 1000.0, "kind" => "terceirizado" } ])
    @pricing.recalculate!
  end

  def workbook(result) = Spreadsheets::Workbook.open(result.bytes)

  def find_row(book, label)
    book.cells("Orçamento").find { |cell| cell.value.to_s.start_with?(label) }&.ref&.then { |ref| ref[/\d+/] }
  end

  test "linhas de equipe, logística e terceiros com fórmula; total bate com o motor" do
    result = Spreadsheets::BudgetBuilder.new(@proposal).call
    book = workbook(result)

    hh_row = find_row(book, "Horas-homem:")
    assert hh_row, "linha de horas-homem"
    assert book.formula?("Orçamento", "F#{hh_row}")
    assert find_row(book, "Serviço terceirizado: Laboratório")
    total_row = find_row(book, "PREÇO TOTAL")
    assert book.formula?("Orçamento", "F#{total_row}")
    assert_in_delta @pricing.total_value.to_f, result.total.to_f, 0.05
    assert_operator result.difference.abs, :<=, 0.05
  end

  test "BDI e impostos são células editáveis que o total usa" do
    book = workbook(Spreadsheets::BudgetBuilder.new(@proposal).call)
    bdi_row = find_row(book, "BDI (multiplicador")

    assert_equal @pricing.bdi.to_f, book.value("Orçamento", "F#{bdi_row}").to_f
    bdi_formula_row = book.cells("Orçamento").find { |cell| cell.value == "BDI" }.ref[/\d+/]
    assert_includes book.cells("Orçamento").find { |cell| cell.ref == "F#{bdi_formula_row}" }.formula.to_s, "$F$#{bdi_row}"
  end

  test "mudar o BDI na planilha muda o preço (recalculado no LibreOffice)" do
    skip "LibreOffice ausente" unless system("which soffice > /dev/null 2>&1")
    result = Spreadsheets::BudgetBuilder.new(@proposal).call
    book = workbook(result)
    bdi_row = find_row(book, "BDI (multiplicador")
    total_ref = "F#{find_row(book, 'PREÇO TOTAL')}"
    book.write("Orçamento", "F#{bdi_row}", 1.5)

    recalculated = Spreadsheets::Recalculator.call(book.to_bytes, ".xlsx")

    assert_operator recalculated.value("Orçamento", total_ref).to_f, :>, result.total.to_f
  end
end
