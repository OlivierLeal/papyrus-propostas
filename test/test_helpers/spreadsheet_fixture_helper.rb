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
