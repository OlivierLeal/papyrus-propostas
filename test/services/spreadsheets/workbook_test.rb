require "test_helper"

class Spreadsheets::WorkbookTest < ActiveSupport::TestCase
  setup { @workbook = Spreadsheets::Workbook.open(client_xlsx_bytes) }

  test "lê abas (com estado), valores e fórmulas" do
    assert_equal [ [ "PPU", "visible" ], [ "Equipe", "hidden" ] ], @workbook.sheets.map { |s| [ s.name, s.state ] }
    assert_equal 100, @workbook.value("PPU", "E3")
    assert @workbook.formula?("PPU", "G3")
    assert_includes @workbook.to_prompt_text, "G5: =SUM(G3:G4)"
    assert_includes @workbook.to_prompt_text, "### Aba \"Equipe\" (oculta)"
  end

  test "nunca escreve por cima de fórmula" do
    assert_raises(Spreadsheets::Workbook::Error) { @workbook.write("PPU", "G3", 10) }
  end

  test "escreve número e texto, e força o recálculo ao salvar" do
    @workbook.write("PPU", "F3", 12.5)
    @workbook.write("PPU", "A1", "LICITANTE: PAPYRUS")
    reopened = Spreadsheets::Workbook.open(@workbook.to_bytes)

    assert_equal 12.5, reopened.value("PPU", "F3")
    assert_equal "LICITANTE: PAPYRUS", reopened.value("PPU", "A1")
    assert_nil reopened.value("PPU", "G5"), "o total em cache (999) tem que sumir pra quem abrir recalcular"
    bytes = reopened.to_bytes
    Zip::File.open_buffer(StringIO.new(bytes)) do |zip|
      assert_nil zip.find_entry("xl/calcChain.xml")
      assert_includes zip.read("xl/workbook.xml"), 'fullCalcOnLoad="1"'
      assert_not_includes zip.read("xl/_rels/workbook.xml.rels"), "calcChain"
    end
  end

  test "replica a linha-modelo com a fórmula traduzida pra cada linha" do
    @workbook.fill_table("Equipe", 2, [ { "A" => "Ana", "B" => 10 }, { "A" => "Bruno", "B" => 4 } ])
    reopened = Spreadsheets::Workbook.open(@workbook.to_bytes)

    assert_equal "Bruno", reopened.value("Equipe", "A3")
    assert_equal "B3*2", reopened.cells("Equipe").find { |c| c.ref == "C3" }.formula
  end

  test "mostra aba oculta" do
    @workbook.unhide("Equipe")
    assert_equal "visible", Spreadsheets::Workbook.open(@workbook.to_bytes).sheet("Equipe").state
  end
end
