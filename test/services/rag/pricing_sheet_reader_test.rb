require "test_helper"

module Rag
  # XLSX é zip com XML dentro (igual DOCX/KMZ), lido com o rubyzip que já é dependência. Os
  # testes montam planilhas mínimas de verdade em disco e conferem a resolução de sharedStrings,
  # strings inline, o teto de linhas e a degradação sem quebrar quando o arquivo não abre.
  class PricingSheetReaderTest < ActiveSupport::TestCase
    test "lê linhas e resolve as strings do dicionário compartilhado" do
      path = build_xlsx(
        shared: [ "Profissional", "Coordenador" ],
        sheets: [ [ [ { s: 0 }, { s: 1 } ], [ { n: 120 }, { n: 40 } ] ] ]
      )

      result = PricingSheetReader.new(path).call

      assert_equal 1, result.sheets.size
      assert_equal "sheet1", result.sheets.first.name
      assert_equal [ %w[Profissional Coordenador], %w[120 40] ], result.sheets.first.rows
      assert_equal 2, result.row_count
    end

    test "entende células de string inline" do
      path = build_xlsx(sheets: [ [ [ { inline: "BDI" }, { n: "1.25" } ] ] ])

      assert_equal [ [ "BDI", "1.25" ] ], PricingSheetReader.new(path).call.sheets.first.rows
    end

    test "pula linha inteiramente vazia" do
      path = build_xlsx(sheets: [ [ [ { n: 1 } ], [ nil, nil ], [ { n: 2 } ] ] ])

      assert_equal [ [ "1" ], [ "2" ] ], PricingSheetReader.new(path).call.sheets.first.rows
    end

    test "corta em MAX_ROWS_PER_SHEET" do
      rows = Array.new(PricingSheetReader::MAX_ROWS_PER_SHEET + 50) { |i| [ { n: i } ] }
      path = build_xlsx(sheets: [ rows ])

      assert_equal PricingSheetReader::MAX_ROWS_PER_SHEET, PricingSheetReader.new(path).call.row_count
    end

    test "várias abas viram várias Sheet, na ordem do nome do arquivo" do
      path = build_xlsx(sheets: [ [ [ { inline: "aba1" } ] ], [ [ { inline: "aba2" } ] ] ])

      result = PricingSheetReader.new(path).call

      assert_equal %w[sheet1 sheet2], result.sheets.map(&:name)
    end

    test "to_text achata as abas num texto buscável" do
      path = build_xlsx(sheets: [ [ [ { inline: "BDI" }, { n: "1.2" } ] ] ])

      texto = PricingSheetReader.new(path).call.to_text

      assert_includes texto, "## Planilha: sheet1"
      assert_includes texto, "BDI | 1.2"
    end

    test "arquivo inexistente devolve resultado vazio sem levantar" do
      result = PricingSheetReader.new("/tmp/nao/existe/planilha.xlsx").call

      assert_empty result.sheets
      assert_equal 0, result.row_count
    end

    test "arquivo que não é zip devolve resultado vazio sem levantar" do
      file = Tempfile.new([ "quebrada", ".xlsx" ])
      file.write("isso não é um zip")
      file.close

      result = PricingSheetReader.new(file.path).call

      assert_empty result.sheets
    ensure
      file&.unlink
    end

    private

    def build_xlsx(sheets:, shared: [])
      buffer = Zip::OutputStream.write_buffer do |zip|
        if shared.any?
          zip.put_next_entry("xl/sharedStrings.xml")
          zip.write(%(<sst xmlns="http://x">#{shared.map { |s| "<si><t>#{s}</t></si>" }.join}</sst>))
        end

        sheets.each_with_index do |rows, index|
          zip.put_next_entry("xl/worksheets/sheet#{index + 1}.xml")
          body = rows.map { |cells| "<row>#{cells.map { |cell| cell_xml(cell) }.join}</row>" }.join
          zip.write(%(<worksheet xmlns="http://x"><sheetData>#{body}</sheetData></worksheet>))
        end
      end

      file = Tempfile.new([ "planilha", ".xlsx" ])
      file.binmode
      file.write(buffer.string)
      file.close
      @tempfiles ||= []
      @tempfiles << file
      file.path
    end

    def cell_xml(cell)
      case cell
      when nil then "<c/>"
      when Hash
        if cell.key?(:s) then %(<c t="s"><v>#{cell[:s]}</v></c>)
        elsif cell.key?(:inline) then %(<c t="inlineStr"><is><t>#{cell[:inline]}</t></is></c>)
        else "<c><v>#{cell[:n]}</v></c>"
        end
      end
    end

    def teardown
      @tempfiles&.each(&:unlink)
    end
  end
end
