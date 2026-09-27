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

  # Precificação reaberta e aprovada de novo gera documento novo (outro checksum): a versão
  # anterior sai das buscas em vez de a mesma proposta ficar duas vezes no acervo.
  test "reaprovação marca a versão anterior da mesma proposta como substituída" do
    attach_document
    stub_embedder { IndexApprovedProposalJob.new.perform(@proposal.id) }
    first = HistoricalProposal.find_by!(conversation: @conversation)

    attach_document(version: 2, extra: "Inclusão de campanha de fauna pedida pelo cliente. ")
    stub_embedder { IndexApprovedProposalJob.new.perform(@proposal.id) }

    records = HistoricalProposal.where(conversation: @conversation)
    assert_equal 2, records.count
    assert first.reload.superseded
    assert_equal [ false ], records.where.not(id: first.id).pluck(:superseded)
  end

  private

  # DOCX real com estrutura de proposta, para exercitar extração e chunking de verdade.
  def attach_document(version: 1, extra: "")
    buffer = Zip::OutputStream.write_buffer do |zip|
      zip.put_next_entry("word/document.xml")
      zip.write(<<~XML)
        <w:document xmlns:w="x"><w:body>
          <w:p><w:pPr><w:pStyle w:val="Ttulo1"/></w:pPr><w:r><w:t>OBJETIVO DOS SERVIÇOS</w:t></w:r></w:p>
          <w:p><w:r><w:t>#{extra}#{'Elaboração de estudo ambiental para licenciamento do empreendimento. ' * 8}</w:t></w:r></w:p>
        </w:body></w:document>
      XML
    end

    @proposal.generated_documents.attach(
      io: StringIO.new(buffer.string), filename: "proposta_tecnica.docx",
      metadata: { "version" => version, "description" => "Emissão Inicial" }
    )
  end
end
