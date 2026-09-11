require "test_helper"

class InsertScheduleSectionToolTest < ActiveSupport::TestCase
  NS_W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main".freeze

  setup do
    @proposal = proposals(:priced_proposal)
    @pricing = @proposal.project_pricing
    @conversation = @proposal.conversation
    @tool = InsertScheduleSectionTool.new(proposal: @proposal)
  end

  test "insere a seção de cronograma no .docx anexado e devolve o card de download" do
    add_schedule_items
    attach_docx("proposta_revisada.docx")

    result = JSON.parse(@tool.execute)

    assert result["success"], result.inspect
    assert_equal @proposal.version, result["version"]
    assert_equal [ "proposta_revisada_com_Cronograma.docx" ], result["filenames"]

    doc = @proposal.reload.generated_documents.sole
    assert_equal "proposta_revisada_com_Cronograma.docx", doc.filename.to_s
    assert_equal "revised_with_schedule", doc.blob.metadata["kind"]
    xml = read_document_xml(doc)
    assert_includes xml, "Quadro 10-1: Cronograma do"
    assert_includes xml, 'w:orient="landscape"'
  end

  test "só o payload de servico carrega os marcos do infográfico (schedule_key_points)" do
    add_schedule_items
    @pricing.update!(
      schedule_empreendimento_start_date: Date.new(2026, 3, 1),
      schedule_key_points: [ { "nome" => "Protocolo no órgão", "periodo" => 3 } ]
    )
    @pricing.schedule_items.create!(schedule_type: "implantacao", phase_name: "Obra",
      activity_name: "Terraplenagem", start_period: 1, duration_periods: 4, position: 0)

    schedules = @tool.send(:build_schedules, @pricing.reload)

    assert_equal [ { "nome" => "Protocolo no órgão", "periodo" => 3 } ], schedules["servico"][:key_points]
    assert_not schedules["implantacao"].key?(:key_points)
  end

  test "enfileira ElectScheduleKeyPointsJob e usa default_schedule_key_points quando schedule_key_points está vazio" do
    add_schedule_items
    @pricing.update!(schedule_key_points: [])
    attach_docx("proposta_revisada.docx")

    assert_enqueued_with(job: ElectScheduleKeyPointsJob, args: [ @proposal.id ]) do
      result = JSON.parse(@tool.execute)
      assert result["success"]
      assert_includes result["message"], "selecionando os principais marcos"
    end

    schedules = @tool.send(:build_schedules, @pricing.reload)
    assert_operator schedules["servico"][:key_points].size, :<=, 6
    assert_operator schedules["servico"][:key_points].size, :>=, 1
  end

  test "sem nenhum .docx anexado, devolve erro e não anexa nada" do
    add_schedule_items

    result = JSON.parse(@tool.execute)

    assert result["error"].present?
    assert_equal 0, @proposal.reload.generated_documents.count
  end

  test "sem itens de cronograma, enfileira a sugestão em background e pede pra tentar de novo" do
    attach_docx("proposta_revisada.docx")

    assert_enqueued_with(job: SuggestScheduleJob, args: [ @proposal.id ]) do
      result = JSON.parse(@tool.execute)
      assert result["aviso"].present?
    end
    assert_equal 0, @proposal.reload.generated_documents.count
  end

  test "sem data de início, presume o início do mês que vem antes de montar" do
    add_schedule_items(start_date: nil)
    attach_docx("proposta_revisada.docx")

    JSON.parse(@tool.execute)

    assert_equal Date.current.next_month.beginning_of_month, @pricing.reload.schedule_papyrus_start_date
  end

  private

  def add_schedule_items(start_date: Date.new(2026, 1, 15))
    @pricing.update!(schedule_papyrus_start_date: start_date)
    @pricing.schedule_items.create!(schedule_type: "servico", phase_name: "Mobilização",
      activity_name: "Assinatura do Contrato", start_period: 1, duration_periods: 1, position: 0)
    @pricing.schedule_items.create!(schedule_type: "servico", phase_name: "Diagnóstico",
      activity_name: "Campanha de Campo", start_period: 2, duration_periods: 3, position: 1)
  end

  def attach_docx(filename)
    message = @conversation.messages.create!(role: "user", content: "segue a versão revisada", internal: false)
    message.attachments.attach(
      io: StringIO.new(minimal_docx), filename: filename,
      content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
      metadata: { kind: "complementary" }
    )
  end

  # .docx mínimo com uma seção "PRAZO DE EXECUÇÃO" (âncora) seguida de outra seção de nível 1.
  def minimal_docx
    document = <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <w:document xmlns:w="#{NS_W}"><w:body>
        <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>PRAZO DE EXECUÇÃO</w:t></w:r></w:p>
        <w:p><w:r><w:t>O prazo é de 12 meses.</w:t></w:r></w:p>
        <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>VALIDADE DA PROPOSTA</w:t></w:r></w:p>
        <w:sectPr><w:headerReference w:type="default" r:id="rId1"/><w:pgSz w:w="11906" w:h="16838"/></w:sectPr>
      </w:body></w:document>
    XML

    Zip::OutputStream.write_buffer do |zip|
      zip.put_next_entry("[Content_Types].xml")
      zip.write('<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' \
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' \
        '<Default Extension="png" ContentType="image/png"/>' \
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>')
      zip.put_next_entry("word/_rels/document.xml.rels")
      zip.write('<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>')
      zip.put_next_entry("word/document.xml")
      zip.write(document)
    end.string
  end

  def read_document_xml(document)
    Tempfile.create([ "gen", ".docx" ], binmode: true) do |tmp|
      tmp.write(document.blob.download)
      tmp.flush
      Zip::File.open(tmp.path) { |zip| return zip.read("word/document.xml").force_encoding("UTF-8") }
    end
  end
end
