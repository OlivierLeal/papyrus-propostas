require "test_helper"

class HistoricalProposalTest < ActiveSupport::TestCase
  setup { @conversation = conversations(:reviewing_conversation) }

  test "nasce pendente (revisão manual) e fora da busca até aprovar" do
    record = build_pending

    assert record.pending?
    assert record.chunks.empty?
    assert_not HistoricalProposalChunk.embedded.exists?(historical_proposal: record),
      "documento não revisado não pode ser recuperado como se fosse voz da Papyrus"
  end

  test "aprovar chunka e embeda o texto pendente, e limpa pending_text" do
    record = build_pending

    stub_embedder { record.approve!(users(:one)) }

    assert record.approved?
    assert_equal users(:one), record.submitted_by
    assert_nil record.pending_text
    assert record.chunks.any?
    assert record.chunks.all? { |chunk| chunk.embedding.present? }
    assert HistoricalProposalChunk.embedded.exists?(historical_proposal: record)
  end

  test "rejeitar não cria chunk nenhum e limpa o texto pendente" do
    record = build_pending

    record.reject!(users(:one))

    assert record.rejected?
    assert_equal users(:one), record.submitted_by
    assert_nil record.pending_text
    assert record.chunks.empty?
  end

  test "registro aprovado por engano sem embeddar continua inencontrável" do
    record = build_pending
    record.update!(review_status: "approved", pending_text: nil)

    assert_not HistoricalProposalChunk.embedded.exists?(historical_proposal: record),
      "aprovado sem vetor é inencontrável — a atomicidade é o que protege a busca, não um filtro à parte"
  end

  test "falha ao embedar reverte tudo — status e pending_text voltam como estavam" do
    record = build_pending
    original = Rag::Embedder.instance_method(:embed_documents)
    Rag::Embedder.define_method(:embed_documents) { |_| raise Rag::Embedder::Error, "Bedrock fora" }

    assert_raises(Rag::Embedder::Error) { record.approve!(users(:one)) }

    assert record.reload.pending?
    assert record.pending_text.present?
    assert record.chunks.empty?
  ensure
    Rag::Embedder.define_method(:embed_documents, original)
  end

  test "review_status fora do menu é recusado" do
    record = build_pending
    record.review_status = "outro_qualquer"

    assert_not record.valid?
    assert_includes record.errors[:review_status], "não está incluído na lista"
  end

  private

  def build_pending
    HistoricalProposal.create!(
      source_sha256: SecureRandom.hex(32), origin: "revisao_manual", conversation: @conversation,
      job_name: "PTC26099", job_number: "PTC26099", client_name: @conversation.client_name,
      source_path: "active_storage:x", relative_path: "proposta_revisada.docx",
      filename: "proposta_revisada.docx", chunker_version: "1", role: "proposta_papyrus",
      role_source: "consultor", status: "ok", review_status: "pending",
      pending_text: "1. OBJETIVO DOS SERVIÇOS\n\n#{'Elaboração de estudo ambiental. ' * 10}"
    )
  end
end
