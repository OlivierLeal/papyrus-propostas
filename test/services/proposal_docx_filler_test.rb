require "test_helper"
require "tempfile"

class ProposalDocxFillerTest < ActiveSupport::TestCase
  TEMPLATE_PATH = Rails.root.join("app/templates/docx/proposta_tecnica_comercial.docx")
  NS = { "w" => "http://schemas.openxmlformats.org/wordprocessingml/2006/main" }.freeze

  setup do
    @filler = ProposalDocxFiller.new(TEMPLATE_PATH)
    @placeholders = {
      "NUMERO_PROPOSTA" => "PTC00042",
      "NOME_CLIENTE" => "Serra Verde Energias Renováveis S.A.",
      "OBJETIVO_SERVICOS" => "Elaborar o EIA/RIMA do Parque Eólico Serra Verde."
    }
    @tables = {
      1 => { rows: [ [ "EIA", "1", "Digital (PDF)" ], [ "RIMA", "1", "Digital (PDF)" ] ] },
      3 => { rows: [ [ "Coordenação geral", "15.000,00" ], [ "Diagnóstico de fauna", "28.260,00" ] ], auto_number: true },
      4 => { rows: [ [ "Assinatura do contrato", "30%" ] ], auto_number: true }
    }
  end

  test "fill does not modify the original template file" do
    original_bytes = File.binread(TEMPLATE_PATH)

    @filler.fill(placeholders: @placeholders, tables: @tables)

    assert_equal original_bytes, File.binread(TEMPLATE_PATH)
  end

  test "fill replaces every simple placeholder and leaves the rest of the document intact" do
    bytes = @filler.fill(placeholders: @placeholders, tables: @tables)
    xml = document_xml(bytes)

    assert_includes xml, "Serra Verde Energias Renováveis S.A."
    assert_includes xml, "Elaborar o EIA/RIMA do Parque Eólico Serra Verde."
    assert_not_includes xml, "{{NOME_CLIENTE}}"
    assert_not_includes xml, "{{OBJETIVO_SERVICOS}}"
    # Institutional/fixed content from the template stays untouched.
    assert_includes xml, "PAPYRUS CONSULTORIA AMBIENTAL LTDA"
  end

  test "fill leaves placeholders with no supplied value as-is instead of blanking them" do
    bytes = @filler.fill(placeholders: { "NOME_CLIENTE" => "Só isso" }, tables: {})
    xml = document_xml(bytes)

    assert_includes xml, "{{OBJETIVO_SERVICOS}}"
  end

  test "fill_table grows the table to fit every data row" do
    bytes = @filler.fill(placeholders: @placeholders, tables: @tables)
    doc = parsed_document(bytes)

    produtos_table = doc.xpath("//w:tbl", NS)[1]
    data_rows = produtos_table.xpath(".//w:tr", NS)[1..]
    assert_equal 2, data_rows.size
    assert_includes cell_texts(data_rows[0]), "EIA"
    assert_includes cell_texts(data_rows[1]), "RIMA"
  end

  test "fill_table shrinks the table when there are fewer rows than the template molde" do
    # Quadro 10-2 (Desembolso) tem 9 linhas moldadas; passamos só 1.
    bytes = @filler.fill(placeholders: @placeholders, tables: @tables)
    doc = parsed_document(bytes)

    desembolso_table = doc.xpath("//w:tbl", NS)[4]
    data_rows = desembolso_table.xpath(".//w:tr", NS)[1..]

    assert_equal 1, data_rows.size
    assert_includes cell_texts(data_rows[0]), "Assinatura do contrato"
  end

  test "fill_table auto-numbers the first column and shifts the supplied values right" do
    bytes = @filler.fill(placeholders: @placeholders, tables: @tables)
    doc = parsed_document(bytes)

    preco_table = doc.xpath("//w:tbl", NS)[3]
    row = preco_table.xpath(".//w:tr", NS)[1]
    cells = cell_texts(row)

    assert_equal "1", cells[0]
    assert_equal "Coordenação geral", cells[1]
    assert_equal "15.000,00", cells[2]
  end

  test "fill turns multi-paragraph placeholder text into separate justified paragraphs" do
    multiline = "Primeiro parágrafo do objetivo.\n\nSegundo parágrafo do objetivo."
    bytes = @filler.fill(placeholders: @placeholders.merge("OBJETIVO_SERVICOS" => multiline), tables: @tables)
    doc = parsed_document(bytes)

    first_p = doc.xpath("//w:p[.//w:t[contains(text(), 'Primeiro parágrafo')]]", NS).first
    second_p = doc.xpath("//w:p[.//w:t[contains(text(), 'Segundo parágrafo')]]", NS).first

    assert first_p.present?
    assert second_p.present?
    assert_not_equal first_p, second_p # parágrafos <w:p> de verdade, não um só com "\n" cru
    assert_equal "both", first_p.at_xpath(".//w:pPr/w:jc", NS)["w:val"]
    assert_equal "both", second_p.at_xpath(".//w:pPr/w:jc", NS)["w:val"]
  end

  test "fill_table also fills the SUMÁRIO DE REVISÕES table (index 0), same as any other table" do
    tables = @tables.merge(0 => { rows: [ [ "01", "Ajuste de escopo", "18/08/2026" ] ] })
    bytes = @filler.fill(placeholders: @placeholders, tables: tables)
    doc = parsed_document(bytes)

    revisoes_table = doc.xpath("//w:tbl", NS)[0]
    data_rows = revisoes_table.xpath(".//w:tr", NS)[1..]

    assert_equal 1, data_rows.size
    assert_equal [ "01", "Ajuste de escopo", "18/08/2026" ], cell_texts(data_rows[0])
  end

  test "fill_split produces two documents that only share the front matter" do
    result = @filler.fill_split(placeholders: @placeholders, tables: @tables)

    technical_xml = document_xml(result[:technical])
    commercial_xml = document_xml(result[:commercial])

    # Compartilhado (carta de apresentação) nos dois.
    assert_includes technical_xml, "Serra Verde Energias Renováveis S.A."
    assert_includes commercial_xml, "Serra Verde Energias Renováveis S.A."

    # Só a técnica tem o objetivo dos serviços (seção 3).
    assert_includes technical_xml, "Elaborar o EIA/RIMA do Parque Eólico Serra Verde."
    assert_not_includes commercial_xml, "Elaborar o EIA/RIMA do Parque Eólico Serra Verde."

    # Só a comercial tem o quadro de preço (seção 10).
    assert_includes commercial_xml, "PREÇO E CONDIÇÕES DE PAGAMENTO"
    assert_not_includes technical_xml, "PREÇO E CONDIÇÕES DE PAGAMENTO"
  end

  test "fill_split applies technical_overrides and commercial_overrides on top of the shared placeholders" do
    result = @filler.fill_split(
      placeholders: @placeholders, tables: @tables,
      technical_overrides: { "NOME_CLIENTE" => "Só na Técnica" },
      commercial_overrides: { "NOME_CLIENTE" => "Só na Comercial" }
    )

    technical_xml = document_xml(result[:technical])
    commercial_xml = document_xml(result[:commercial])

    assert_includes technical_xml, "Só na Técnica"
    assert_not_includes technical_xml, "Só na Comercial"
    assert_includes commercial_xml, "Só na Comercial"
    assert_not_includes commercial_xml, "Só na Técnica"
  end

  test "fill_split keeps both resulting files valid, openable zip packages" do
    result = @filler.fill_split(placeholders: @placeholders, tables: @tables)

    result.each_value do |bytes|
      Tempfile.create([ "split", ".docx" ], binmode: true) do |tmp|
        tmp.write(bytes)
        tmp.flush

        Zip::File.open(tmp.path) do |zip|
          assert zip.find_entry("[Content_Types].xml")
          assert zip.find_entry("_rels/.rels")
          assert zip.find_entry("word/document.xml")
        end
      end
    end
  end

  private
    def document_xml(bytes)
      Tempfile.create([ "proposal", ".docx" ], binmode: true) do |tmp|
        tmp.write(bytes)
        tmp.flush
        Zip::File.open(tmp.path) { |zip| return zip.read("word/document.xml").force_encoding("UTF-8") }
      end
    end

    def parsed_document(bytes)
      Nokogiri::XML(document_xml(bytes))
    end

    def cell_texts(row)
      row.xpath(".//w:tc", NS).map { |cell| cell.xpath(".//w:t", NS).map(&:text).join }
    end
end
