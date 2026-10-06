require "test_helper"

# TR do estudo como Anexo I, em texto editável (2026-10). Ver app/services/term_of_reference_annex.rb.
class TermOfReferenceAnnexTest < ActiveSupport::TestCase
  W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

  setup do
    @conversation = conversations(:priced_conversation)
  end

  test "TR em Word: título pelo estilo, parágrafo, item de lista, figura vira marcação e tabela vira tabela" do
    annex = TermOfReferenceAnnex.build([ attach_docx(tr_docx_bytes) ]).annexes.first
    kinds = annex.blocks.map(&:kind)

    assert_equal TermOfReferenceAnnex::TITLE, annex.title
    assert_equal %i[heading paragraph list figure table], kinds
    assert_equal "1. Diagnóstico do meio biótico", annex.blocks.first.text
    assert_equal [ [ "Grupo", "Campanhas" ], [ "Avifauna", "2" ] ], annex.blocks.last.rows
  end

  test "TR em PDF: junta o número com o título, tira o sumário, junta palavra hifenizada e separa a lista" do
    page = <<~TEXT
      Sumário
      1.
      OBJETIVO ......................................... 3

      1.
      OBJETIVO
      O estudo deverá contem-
      plar a área de influência direta.

      • Inventário florestal
      • Levantamento de fauna
      3
    TEXT
    blocks = TermOfReferenceAnnex::Reader.new(nil).send(:page_blocks, page)

    assert_equal [ [ :heading, "1. OBJETIVO" ], [ :paragraph, "O estudo deverá contemplar a área de influência direta." ],
                   [ :list, "Inventário florestal" ], [ :list, "Levantamento de fauna" ] ], blocks.map { |b| [ b.kind, b.text ] }
  end

  # PDF do SEI com Calibri: a ligadura "ti" vira espaço e "fi" vira o caractere de ligadura.
  test "PDF com ligadura perdida volta a ler palavra inteira, sem colar palavras de um PDF normal" do
    reader = TermOfReferenceAnnex::Reader.new(nil)

    assert_equal "o objetivo da atividade, Justificar a política e as características marítimas utilizadas",
      reader.send(:repair_ligatures, "o obje vo da a vidade, Jus ﬁcar a polí ca e as caracterís cas marí mas u lizadas")
    assert_equal "a vencedora fica ciente e deverá ficar demonstrado", reader.send(:repair_ligatures, "a vencedora fica ciente e deverá ficar demonstrado")
  end

  test "XML do anexo: página nova, fora da numeração dos capítulos, lista com o marcador do modelo e tabela" do
    annex = TermOfReferenceAnnex.build([ attach_docx(tr_docx_bytes) ]).annexes.first
    xml = TermOfReferenceAnnex::Writer.title_xml(annex.title) + annex.content_xml
    doc = Nokogiri::XML("<w:body xmlns:w=\"#{W}\">#{xml}</w:body>")
    ns = { "w" => W }
    title = doc.at_xpath("//w:p", ns)

    assert title.at_xpath(".//w:pageBreakBefore", ns)
    assert title.at_xpath(".//w:outlineLvl", ns), "aparece na navegação do Word"
    assert_nil title.at_xpath(".//w:pStyle", ns), "sem o estilo Título 1, não vira capítulo numerado"
    assert_equal "2", doc.at_xpath("//w:numId", ns)["w:val"]
    assert_equal 2, doc.xpath("//w:tbl/w:tr", ns).size
    assert_includes doc.xpath("//w:t", ns).map(&:text), TermOfReferenceAnnex::FIGURE_PLACEHOLDER
  end

  test "arquivo ilegível não derruba a geração: o anexo some" do
    message = @conversation.messages.create!(role: "user", content: "TR")
    message.attachments.attach(io: StringIO.new("não é um zip"), filename: "tr.docx")

    assert_empty TermOfReferenceAnnex.build(message.attachments.to_a).annexes
  end

  # Proposta 34 (2026-10): o "TR" era a portaria da licença. O anexo leva o nome do que o documento é,
  # e documento comercial/contratual não entra. Sem a leitura da IA, vale o nome do arquivo.
  test "título pelo tipo real do documento; contratual/comercial fica de fora; a leitura da IA vence o nome" do
    portaria = attach_named("EOL-FLO-MA_LP - Portaria 25.288_2022-1.docx")
    minuta = attach_named("Minuta_Padrão_de_Prestação_de_Serviços_-_2024.docx")
    plan = TermOfReferenceAnnex.labels([ portaria, minuta ])

    assert_equal [ "ANEXO I – PORTARIA Nº 25.288/2022" ], plan.annexes.map(&:title)
    assert_equal "Portaria nº 25.288/2022 (Anexo I)", plan.annexes.first.label
    assert_equal [ [ minuta.filename.to_s, "Minuta de contrato" ] ], plan.skipped

    profiles = { minuta.blob_id.to_s => { "tipo" => "Licença", "numero" => "1/2024", "anexar" => true } }
    assert_equal [ "ANEXO I – PORTARIA Nº 25.288/2022", "ANEXO II – LICENÇA Nº 1/2024" ],
      TermOfReferenceAnnex.labels([ portaria, minuta ], profiles: profiles).annexes.map(&:title)
  end

  private

  def attach_named(filename)
    message = @conversation.messages.create!(role: "user", content: "TR")
    message.attachments.attach(io: StringIO.new(tr_docx_bytes), filename: filename)
    message.attachments.last
  end

  def attach_docx(bytes)
    message = @conversation.messages.create!(role: "user", content: "TR")
    message.attachments.attach(io: StringIO.new(bytes), filename: "TR #{SecureRandom.hex(3)}.docx")
    message.attachments.last
  end

  def tr_docx_bytes
    body = <<~XML
      <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>1. Diagnóstico do meio biótico</w:t></w:r></w:p>
      <w:p><w:r><w:t>Apresentar o diagnóstico de fauna e flora.</w:t></w:r></w:p>
      <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="4"/></w:numPr></w:pPr><w:r><w:t>Duas campanhas sazonais</w:t></w:r></w:p>
      <w:p><w:r><w:drawing/></w:r></w:p>
      <w:p><w:r><w:t></w:t></w:r></w:p>
      <w:tbl><w:tr><w:tc><w:p><w:r><w:t>Grupo</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Campanhas</w:t></w:r></w:p></w:tc></w:tr>
      <w:tr><w:tc><w:p><w:r><w:t>Avifauna</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>2</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
    XML
    buffer = Zip::OutputStream.write_buffer do |zip|
      zip.put_next_entry("word/document.xml")
      zip.write(%(<?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="#{W}"><w:body>#{body}</w:body></w:document>))
    end
    buffer.string
  end
end
