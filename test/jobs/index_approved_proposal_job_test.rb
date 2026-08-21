require "test_helper"

class IndexApprovedProposalJobTest < ActiveJob::TestCase
  setup do
    @conversation = conversations(:reviewing_conversation)
    @proposal = @conversation.create_proposal!(status: "approved", version: 1)
  end

  test "indexa a proposta aprovada marcando que veio do sistema, não do acervo" do
    attach_document

    stub_embedder { IndexApprovedProposalJob.new.perform(@proposal.id) }

    record = HistoricalProposal.find_by(conversation: @conversation)
    assert record, "a proposta aprovada precisa entrar no acervo"
    assert_equal "sistema", record.origin,
      "sem isso não dá para distinguir proposta histórica assinada de saída deste sistema"
    assert_equal "proposta_papyrus", record.role
    assert_equal @conversation.client_name, record.client_name
    assert record.chunks.any?
    assert record.chunks.all? { |chunk| chunk.embedding.present? }
  end

  test "proposta ainda não aprovada não é indexada" do
    attach_document
    @proposal.update!(status: "draft")

    stub_embedder { IndexApprovedProposalJob.new.perform(@proposal.id) }

    assert_nil HistoricalProposal.find_by(conversation: @conversation),
      "rascunho descartado depois não pode virar referência para propostas futuras"
  end

  test "proposta sem documento gerado não quebra o job" do
    assert_nothing_raised { IndexApprovedProposalJob.new.perform(@proposal.id) }
    assert_nil HistoricalProposal.find_by(conversation: @conversation)
  end

  test "reindexar a mesma proposta não duplica" do
    attach_document

    stub_embedder do
      2.times { IndexApprovedProposalJob.new.perform(@proposal.id) }
    end

    assert_equal 1, HistoricalProposal.where(conversation: @conversation).count
  end

  test "falha ao indexar não propaga para a aprovação que o consultor acabou de fazer" do
    attach_document
    original = Rag::Embedder.instance_method(:embed_documents)
    Rag::Embedder.define_method(:embed_documents) { |_| raise Rag::Embedder::Error, "Bedrock fora" }

    assert_nothing_raised { IndexApprovedProposalJob.new.perform(@proposal.id) }
  ensure
    Rag::Embedder.define_method(:embed_documents, original)
  end

  private

  # DOCX real com estrutura de proposta, para exercitar extração e chunking de verdade.
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

    @proposal.generated_documents.attach(
      io: StringIO.new(buffer.string), filename: "proposta_tecnica.docx",
      metadata: { "version" => 1, "description" => "Emissão Inicial" }
    )
  end
end
