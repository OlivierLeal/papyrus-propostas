# Monta um .xlsx de verdade (zip + XML, como o Excel grava) pra testar a leitura de planilha sem
# depender de arquivo binário no repositório. Duas abas com nome ("Orçamento", "Quantitativos"),
# strings compartilhadas e uma linha com célula vazia no meio (A e C preenchidas, B não).
module SpreadsheetFixtureHelper
  def xlsx_bytes
    sheet = ->(rows) do
      body = rows.each_with_index.map do |cells, r|
        cols = cells.map { |ref, xml| %(<c r="#{ref}#{r + 1}"#{xml}</c>) }.join
        %(<row r="#{r + 1}">#{cols}</row>)
      end.join
      %(<?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>#{body}</sheetData></worksheet>)
    end

    Zip::OutputStream.write_buffer do |zip|
      zip.put_next_entry("xl/workbook.xml")
      zip.write(%(<?xml version="1.0"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Orçamento" sheetId="1" r:id="rId1"/><sheet name="Quantitativos" sheetId="2" r:id="rId2"/></sheets></workbook>))
      zip.put_next_entry("xl/_rels/workbook.xml.rels")
      zip.write(%(<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Target="worksheets/sheet2.xml"/></Relationships>))
      zip.put_next_entry("xl/sharedStrings.xml")
      zip.write(%(<?xml version="1.0"?><sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><si><t>Item</t></si><si><t>Unidade</t></si><si><t>Valor</t></si><si><t>Levantamento de fauna</t></si><si><t>Campanha</t></si></sst>))
      zip.put_next_entry("xl/worksheets/sheet1.xml")
      zip.write(sheet.call([
        [ [ "A", ' t="s"><v>0</v>' ], [ "B", ' t="s"><v>1</v>' ], [ "C", ' t="s"><v>2</v>' ] ],
        [ [ "A", ' t="s"><v>3</v>' ], [ "C", "><v>12500</v>" ] ]
      ]))
      zip.put_next_entry("xl/worksheets/sheet2.xml")
      zip.write(sheet.call([ [ [ "A", ' t="s"><v>4</v>' ], [ "B", "><v>4</v>" ] ] ]))
    end.string
  end
end

# Planilha de cliente pra testar o PREENCHIMENTO (Spreadsheets::Workbook/PlanExecutor): uma PPU
# (rótulo "LICITANTE:", dois itens com quantidade, preço unitário em branco, total por fórmula com
# valor em cache antigo) e uma aba OCULTA de equipe com linha-modelo de fórmula, mais calcChain.
module ClientSpreadsheetFixtureHelper
  MAIN_NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main".freeze

  def client_xlsx_bytes
    ppu = <<~XML
      <?xml version="1.0"?><worksheet xmlns="#{MAIN_NS}"><sheetData>
      <row r="1"><c r="A1" t="inlineStr"><is><t>LICITANTE:</t></is></c></row>
      <row r="2"><c r="A2" t="inlineStr"><is><t>Item</t></is></c><c r="E2" t="inlineStr"><is><t>Quantidade</t></is></c><c r="F2" t="inlineStr"><is><t>Preço unitário</t></is></c><c r="G2" t="inlineStr"><is><t>Total</t></is></c></row>
      <row r="3"><c r="A3" t="inlineStr"><is><t>Diária embarcada</t></is></c><c r="E3"><v>100</v></c><c r="F3"/><c r="G3"><f>E3*F3</f><v>0</v></c></row>
      <row r="4"><c r="A4" t="inlineStr"><is><t>Relatório por poço</t></is></c><c r="E4"><v>3</v></c><c r="F4"/><c r="G4"><f>E4*F4</f><v>0</v></c></row>
      <row r="5"><c r="A5" t="inlineStr"><is><t>TOTAL GERAL</t></is></c><c r="G5"><f>SUM(G3:G4)</f><v>999</v></c></row>
      </sheetData></worksheet>
    XML
    equipe = <<~XML
      <?xml version="1.0"?><worksheet xmlns="#{MAIN_NS}"><sheetData>
      <row r="1"><c r="A1" t="inlineStr"><is><t>Nome</t></is></c><c r="B1" t="inlineStr"><is><t>Horas</t></is></c><c r="C1" t="inlineStr"><is><t>Dobro</t></is></c></row>
      <row r="2"><c r="A2" s="3"/><c r="B2"/><c r="C2"><f>B2*2</f><v>0</v></c></row>
      <row r="4"><c r="A4" t="inlineStr"><is><t>Total</t></is></c><c r="C4"><f>SUM(C2:C3)</f></c></row>
      </sheetData></worksheet>
    XML

    Zip::OutputStream.write_buffer do |zip|
      {
        "[Content_Types].xml" => %(<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Override PartName="/xl/calcChain.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.calcChain+xml"/></Types>),
        "xl/workbook.xml" => %(<?xml version="1.0"?><workbook xmlns="#{MAIN_NS}" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="PPU" sheetId="1" r:id="rId1"/><sheet name="Equipe" sheetId="2" state="hidden" r:id="rId2"/></sheets><calcPr calcId="1"/></workbook>),
        "xl/_rels/workbook.xml.rels" => %(<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Target="worksheets/sheet2.xml"/><Relationship Id="rId3" Target="calcChain.xml"/></Relationships>),
        "xl/calcChain.xml" => %(<?xml version="1.0"?><calcChain xmlns="#{MAIN_NS}"><c r="G3" i="1"/></calcChain>),
        "xl/worksheets/sheet1.xml" => ppu,
        "xl/worksheets/sheet2.xml" => equipe
      }.each do |name, xml|
        zip.put_next_entry(name)
        zip.write(xml)
      end
    end.string
  end
end
