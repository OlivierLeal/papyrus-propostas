require "test_helper"

class LearnFromRevisedProposalToolTest < ActiveSupport::TestCase
  setup do
    @conversation = conversations(:reviewing_conversation)
    @tool = LearnFromRevisedProposalTool.new(conversation: @conversation)
  end

  test "sem anexo nenhum na conversa, devolve erro" do
    result = JSON.parse(@tool.execute)

    assert_equal "Não encontrei nenhum documento anexado nesta conversa para guardar.", result["error"]
    assert_equal 0, HistoricalProposal.count
  end

  test "com um anexo legível, cria registro pendente e um card no chat" do
    attach_document

    result = JSON.parse(@tool.execute)

    assert result["success"]
    record = HistoricalProposal.find(result["historical_proposal_id"])
    assert record.pending?
    assert_equal "revisao_manual", record.origin
    assert_equal "proposta_papyrus", record.role
    assert_equal "consultor", record.role_source
    assert record.pending_text.present?

    card_message = @conversation.messages.where(role: "assistant").last
    assert_equal({ "historical_proposal_id" => record.id }, JSON.parse(card_message.content))

    # Nada foi indexado ainda — pendente é inencontrável por construção (sem chunk nenhum).
    assert record.chunks.empty?
  end

  test "reenviar o mesmo arquivo não duplica o card" do
    attach_document
    first = JSON.parse(@tool.execute)

    # anexa de novo o mesmo conteúdo, simulando o consultor mandando o arquivo outra vez
    attach_document
    second = JSON.parse(@tool.execute)

    assert_nil second["success"]
    assert second["aviso"].present?
    assert_equal 1, HistoricalProposal.count
    assert_equal first["historical_proposal_id"], HistoricalProposal.first.id
  end

  test "anexo sem texto extraível devolve erro e não cria registro" do
    message = @conversation.messages.create!(role: "user", content: "revisão final", internal: false)
    message.attachments.attach(
      io: StringIO.new("\x00\x01binário sem texto"), filename: "revisado.docx",
      content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
      metadata: { kind: "complementary" }
    )

    result = JSON.parse(@tool.execute)

    assert result["error"].present?
    assert_equal 0, HistoricalProposal.count
  end

  test "ignora anexo de KMZ como se não existisse" do
    message = @conversation.messages.create!(role: "user", content: "kmz", internal: false)
    message.attachments.attach(
      io: StringIO.new("kmz binário"), filename: "area.kmz", content_type: "application/vnd.google-earth.kmz",
      metadata: { kind: "kmz" }
    )

    result = JSON.parse(@tool.execute)

    assert_equal "Não encontrei nenhum documento anexado nesta conversa para guardar.", result["error"]
  end

  private

  def attach_document
    buffer = Zip::OutputStream.write_buffer do |zip|
      zip.put_next_entry("word/document.xml")
      zip.write(<<~XML)
        <w:document xmlns:w="x"><w:body>
          <w:p><w:pPr><w:pStyle w:val="Ttulo1"/></w:pPr><w:r><w:t>OBJETIVO DOS SERVIÇOS</w:t></w:r></w:p>
          <w:p><w:r><w:t>#{'Elaboração de estudo ambiental para licenciamento do empreendimento. ' * 8}</w:t></w:r></w:p>
        </w:body></w:document>
      XML
    end

    message = @conversation.messages.create!(role: "user", content: "versão final revisada", internal: false)
    message.attachments.attach(
      io: StringIO.new(buffer.string), filename: "proposta_revisada.docx",
      content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
      metadata: { kind: "complementary" }
    )
  end
end
