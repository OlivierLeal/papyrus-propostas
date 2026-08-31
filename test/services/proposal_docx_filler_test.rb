require "test_helper"
require "tempfile"

class ProposalDocxFillerTest < ActiveSupport::TestCase
  TEMPLATE_PATH = Rails.root.join("app/templates/docx/proposta_tecnica_comercial.docx")
  NS = { "w" => "http://schemas.openxmlformats.org/wordprocessingml/2006/main" }.freeze
  PNG_1X1 = Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")

  setup do
    @filler = ProposalDocxFiller.new(TEMPLATE_PATH)
    @placeholders = {
      "NUMERO_PROPOSTA" => "PTC00042",
      "NOME_CLIENTE" => "Serra Verde Energias Renováveis S.A.",
      "OBJETIVO_SERVICOS" => "Elaborar o EIA/RIMA do Parque Eólico Serra Verde."
    }
    # Índices são a posição da tabela no modelo: 0 = revisões, 1 = produtos, 2 = equipe,
    # 3 = desembolso (o quadro de preço por linha saiu do modelo na revisão de 2026-08).
    @tables = {
      1 => { rows: [ [ "EIA", "Digital (PDF)" ], [ "RIMA", "Digital (PDF)" ] ] },
      3 => { rows: [ [ "Assinatura do contrato", "13.473,00", "25/03/2026" ] ], auto_number: true }
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

  test "fill fills a token in remove_paragraph_if_blank normally when a value is supplied" do
    bytes = @filler.fill(
      placeholders: @placeholders.merge("OBRIGACOES_PAPYRUS_ADICIONAIS" => "Emitir relatório mensal de acompanhamento."),
      tables: @tables, remove_paragraph_if_blank: %w[OBRIGACOES_PAPYRUS_ADICIONAIS]
    )
    xml = document_xml(bytes)

    assert_includes xml, "Emitir relatório mensal de acompanhamento."
    assert_not_includes xml, "{{OBRIGACOES_PAPYRUS_ADICIONAIS}}"
  end

  test "fill expands multiple lines for a token in remove_paragraph_if_blank into separate list items" do
    bytes = @filler.fill(
      placeholders: @placeholders.merge("OBRIGACOES_CONTRATANTE_ADICIONAIS" => "Fornecer escolta armada.\nDisponibilizar embarcação."),
      tables: @tables, remove_paragraph_if_blank: %w[OBRIGACOES_CONTRATANTE_ADICIONAIS]
    )
    xml = document_xml(bytes)

    assert_includes xml, "Fornecer escolta armada."
    assert_includes xml, "Disponibilizar embarcação."
  end

  test "fill removes the whole paragraph for a blank token listed in remove_paragraph_if_blank" do
    # A chave precisa estar presente com valor "" — igual GenerateProposalDocumentTool sempre
    # manda, mesmo sem nenhum item extra (ver join_lines). Chave ausente cai no outro caso (fill
    # leaves placeholders with no supplied value as-is), não em "valor vazio".
    bytes = @filler.fill(
      placeholders: @placeholders.merge("OBRIGACOES_CONTRATANTE_ADICIONAIS" => "", "OBRIGACOES_PAPYRUS_ADICIONAIS" => ""),
      tables: @tables, remove_paragraph_if_blank: %w[OBRIGACOES_CONTRATANTE_ADICIONAIS OBRIGACOES_PAPYRUS_ADICIONAIS]
    )
    xml = document_xml(bytes)

    assert_not_includes xml, "OBRIGACOES_CONTRATANTE_ADICIONAIS"
    assert_not_includes xml, "OBRIGACOES_PAPYRUS_ADICIONAIS"
  end

  test "fill blanks a token not listed in remove_paragraph_if_blank the normal way, keeping the paragraph" do
    # Comportamento padrão de qualquer outro placeholder — não regride pros tokens que não pedem
    # o item de lista sumir (ex.: MAPA_AREA_ESTUDO, que fica com o parágrafo mas texto vazio).
    kept = @filler.fill(
      placeholders: @placeholders.merge("OBRIGACOES_CONTRATANTE_ADICIONAIS" => ""),
      tables: @tables, remove_paragraph_if_blank: []
    )
    removed = @filler.fill(
      placeholders: @placeholders.merge("OBRIGACOES_CONTRATANTE_ADICIONAIS" => ""),
      tables: @tables, remove_paragraph_if_blank: %w[OBRIGACOES_CONTRATANTE_ADICIONAIS]
    )

    kept_paragraphs = parsed_document(kept).xpath("//w:p", NS).size
    removed_paragraphs = parsed_document(removed).xpath("//w:p", NS).size

    assert_equal kept_paragraphs - 1, removed_paragraphs
  end

  test "fill bolds a line wrapped in ** and strips the markers, in a single-value placeholder" do
    bytes = @filler.fill(placeholders: @placeholders.merge("NOME_CLIENTE" => "**Cliente Negrito**"), tables: @tables)
    doc = parsed_document(bytes)

    text_node = doc.xpath("//w:t").find { |t| t.text == "Cliente Negrito" }
    assert text_node.present?, "esperava o texto sem os marcadores **"
    assert text_node.at_xpath("ancestor::w:r/w:rPr/w:b", NS).present?
  end

  test "fill bolds a line wrapped in ** inside a multi-line expanded placeholder, leaving the other lines plain" do
    bytes = @filler.fill(
      placeholders: @placeholders.merge("ESCOPO_METODOLOGIA" => "**5.1 MEIO FÍSICO**\nTexto normal do tópico."),
      tables: @tables
    )
    doc = parsed_document(bytes)

    titulo = doc.xpath("//w:t").find { |t| t.text == "5.1 MEIO FÍSICO" }
    corpo = doc.xpath("//w:t").find { |t| t.text == "Texto normal do tópico." }

    assert titulo.present?
    assert titulo.at_xpath("ancestor::w:r/w:rPr/w:b", NS).present?
    assert corpo.present?
    assert_not corpo.at_xpath("ancestor::w:r/w:rPr/w:b", NS).present?
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
    # Quadro 10-1 (Desembolso) tem 9 linhas moldadas; passamos só 1.
    bytes = @filler.fill(placeholders: @placeholders, tables: @tables)
    doc = parsed_document(bytes)

    desembolso_table = doc.xpath("//w:tbl", NS)[3]
    data_rows = desembolso_table.xpath(".//w:tr", NS)[1..]

    assert_equal 1, data_rows.size
    assert_includes cell_texts(data_rows[0]), "Assinatura do contrato"
  end

  test "fill_table auto-numbers the first column and shifts the supplied values right" do
    bytes = @filler.fill(placeholders: @placeholders, tables: @tables)
    doc = parsed_document(bytes)

    desembolso_table = doc.xpath("//w:tbl", NS)[3]
    row = desembolso_table.xpath(".//w:tr", NS)[1]
    cells = cell_texts(row)

    assert_equal "1", cells[0]
    assert_equal "Assinatura do contrato", cells[1]
    assert_equal "13.473,00", cells[2]
    assert_equal "25/03/2026", cells[3]
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

  # Achado na prática: só o parágrafo de OBJETIVO_SERVICOS tinha w:jc="both" no modelo — os de
  # CARACTERIZACAO_EMPREENDIMENTO e ESCOPO_METODOLOGIA saíam alinhados à esquerda, fora do padrão
  # visual do resto do documento (corrigido direto no .docx do modelo).
  test "fill justifies Caracterização do Empreendimento and Escopo e Metodologia, same as Objetivo dos Serviços" do
    bytes = @filler.fill(
      placeholders: @placeholders.merge(
        "CARACTERIZACAO_EMPREENDIMENTO" => "Texto de caracterização do empreendimento.",
        "ESCOPO_METODOLOGIA" => "Texto de escopo e metodologia."
      ),
      tables: @tables
    )
    doc = parsed_document(bytes)

    caracterizacao_p = doc.xpath("//w:p[.//w:t[contains(text(), 'Texto de caracterização')]]", NS).first
    escopo_p = doc.xpath("//w:p[.//w:t[contains(text(), 'Texto de escopo e metodologia')]]", NS).first

    assert_equal "both", caracterizacao_p&.at_xpath(".//w:pPr/w:jc", NS)&.[]("w:val")
    assert_equal "both", escopo_p&.at_xpath(".//w:pPr/w:jc", NS)&.[]("w:val")
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

    # A fronteira entre as duas é um índice fixo do corpo do modelo (TECHNICAL_SECTIONS), então
    # ela precisa ser fixada nas duas pontas: a última seção técnica inteira fica na técnica.
    assert_includes technical_xml, "PRAZO DE EXECUÇÃO"
    assert_includes technical_xml, "O referido prazo poderá ter alterações"
    assert_not_includes commercial_xml, "PRAZO DE EXECUÇÃO"
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

  test "fill embeds a real image when images: is given, and the placeholder text disappears" do
    bytes = @filler.fill(placeholders: @placeholders, tables: @tables, images: { "MAPA_AREA_ESTUDO" => PNG_1X1 })
    xml = document_xml(bytes)

    assert_includes xml, "<w:drawing>"
    assert_includes xml, "rId_MAPA_AREA_ESTUDO"
    assert_not_includes xml, "{{MAPA_AREA_ESTUDO}}"
    assert_includes zip_entry_names(bytes), "word/media/mapa_area_estudo.png"

    rels = zip_entry_content(bytes, "word/_rels/document.xml.rels")
    assert_includes rels, %(Id="rId_MAPA_AREA_ESTUDO")
    assert_includes rels, %(Target="media/mapa_area_estudo.png")
  end

  test "fill leaves the placeholder as plain text when no image is supplied for it" do
    bytes = @filler.fill(placeholders: @placeholders.merge("MAPA_AREA_ESTUDO" => ""), tables: @tables, images: {})
    xml = document_xml(bytes)

    assert_not_includes xml, "{{MAPA_AREA_ESTUDO}}"
    assert_not_includes xml, "rId_MAPA_AREA_ESTUDO"
    assert_not_includes zip_entry_names(bytes), "word/media/mapa_area_estudo.png"
  end

  test "fill_split only keeps the map image in the technical variant (Caracterização do Empreendimento is section 4)" do
    result = @filler.fill_split(placeholders: @placeholders, tables: @tables, images: { "MAPA_AREA_ESTUDO" => PNG_1X1 })

    technical_xml = document_xml(result[:technical])
    commercial_xml = document_xml(result[:commercial])

    assert_includes technical_xml, "rId_MAPA_AREA_ESTUDO"
    assert_not_includes commercial_xml, "rId_MAPA_AREA_ESTUDO"
  end

  test "fill_split still produces openable docx files when an image is embedded" do
    result = @filler.fill_split(placeholders: @placeholders, tables: @tables, images: { "MAPA_AREA_ESTUDO" => PNG_1X1 })

    result.each_value do |bytes|
      Tempfile.create([ "split", ".docx" ], binmode: true) do |tmp|
        tmp.write(bytes)
        tmp.flush

        Zip::File.open(tmp.path) do |zip|
          assert zip.find_entry("[Content_Types].xml")
          assert zip.find_entry("word/document.xml")
        end
      end
    end
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

    def zip_entry_names(bytes)
      Tempfile.create([ "proposal", ".docx" ], binmode: true) do |tmp|
        tmp.write(bytes)
        tmp.flush
        Zip::File.open(tmp.path) { |zip| return zip.entries.map(&:name) }
      end
    end

    def zip_entry_content(bytes, entry_name)
      Tempfile.create([ "proposal", ".docx" ], binmode: true) do |tmp|
        tmp.write(bytes)
        tmp.flush
        Zip::File.open(tmp.path) { |zip| return zip.read(entry_name).force_encoding("UTF-8") }
      end
    end


  # REGRESSÃO — proposta PT26011 (produção, agosto/2026): a técnica saiu terminando no segundo
  # item das obrigações da Papyrus, no meio da seção 7. A causa não era o conteúdo: o texto da IA
  # vira parágrafos de verdade ANTES do corte, e o corte usava índices mapeados no modelo vazio,
  # então quanto mais a IA escrevia, mais cedo o documento era cortado.
  test "fill_split keeps every technical section even when the AI text expands the body a lot" do
    escopo = Array.new(60) { |i| "Parágrafo #{i + 1} do escopo e metodologia de execução do serviço." }.join("\n\n")

    result = @filler.fill_split(
      placeholders: @placeholders.merge("ESCOPO_METODOLOGIA" => escopo), tables: @tables
    )
    technical_xml = document_xml(result[:technical])

    assert_includes technical_xml, "Parágrafo 60 do escopo"
    # Tudo que vem DEPOIS do texto expandido tem que continuar no documento.
    assert_includes technical_xml, "PRODUTOS A SEREM ENTREGUES"
    assert_includes technical_xml, "RESPONSABILIDADES DAS PARTES"
    assert_includes technical_xml, "Disponibilizar a Lista de stakeholders." # último item da seção 7
    assert_includes technical_xml, "EQUIPE TÉCNICA"
    assert_includes technical_xml, "PRAZO DE EXECUÇÃO"
    # VALIDADE DA PROPOSTA (2026-08) foi movida pra antes de PREÇO E CONDIÇÕES DE PAGAMENTO
    # justamente pra sair também na proposta só-técnica — antes ficava do lado comercial.
    assert_includes technical_xml, "VALIDADE DA PROPOSTA"
    # E a fronteira continua valendo: a parte comercial não vaza para a técnica.
    assert_not_includes technical_xml, "PREÇO E CONDIÇÕES DE PAGAMENTO"
  end

  test "fill_split keeps the commercial half whole under the same expansion" do
    escopo = Array.new(60) { |i| "Parágrafo #{i + 1} do escopo." }.join("\n\n")

    result = @filler.fill_split(
      placeholders: @placeholders.merge("ESCOPO_METODOLOGIA" => escopo), tables: @tables
    )
    commercial_xml = document_xml(result[:commercial])

    assert_includes commercial_xml, "PREÇO E CONDIÇÕES DE PAGAMENTO"
    assert_includes commercial_xml, "DADOS BANCÁRIOS"
    # VALIDADE DA PROPOSTA ficou do lado técnico agora (ver teste acima) — não duplica aqui.
    assert_not_includes commercial_xml, "VALIDADE DA PROPOSTA"
    assert_not_includes commercial_xml, "Parágrafo 1 do escopo"
    assert_not_includes commercial_xml, "RESPONSABILIDADES DAS PARTES"
  end

  # O modelo é reaberto e salvo pela Papyrus de tempos em tempos, e o salvamento renomeia o estilo
  # dos títulos (o mesmo arquivo já veio com "Ttulo1" e com "Heading1"). O corte não pode depender
  # desse nome.
  test "fill_split finds the section boundary even if the heading style was renamed by a re-save" do
    renamed = Tempfile.create([ "modelo", ".docx" ], binmode: true)
    FileUtils.cp(TEMPLATE_PATH, renamed.path)
    Zip::File.open(renamed.path) do |zip|
      xml = zip.read("word/document.xml").force_encoding("UTF-8").gsub("Heading1", "EstiloQualquer")
      zip.get_output_stream("word/document.xml") { |f| f.write(xml) }
    end

    result = ProposalDocxFiller.new(renamed.path).fill_split(placeholders: @placeholders, tables: @tables)

    assert_includes document_xml(result[:technical]), "PRAZO DE EXECUÇÃO"
    assert_not_includes document_xml(result[:technical]), "PREÇO E CONDIÇÕES DE PAGAMENTO"
  ensure
    renamed&.close
  end

  # Modelo re-salvo grava a célula vazia da linha-molde como um run só com <w:rPr>, sem <w:t>.
  # Assumir que o primeiro run tinha texto derrubava a geração inteira.
  test "fill_table writes into a template cell whose run has no text node at all" do
    bytes = @filler.fill(placeholders: @placeholders, tables: @tables)
    doc = parsed_document(bytes)

    desembolso_table = doc.xpath("//w:tbl", NS)[3]
    assert_equal [ "1", "Assinatura do contrato", "13.473,00", "25/03/2026" ],
                 cell_texts(desembolso_table.xpath(".//w:tr", NS)[1])
  end
end
