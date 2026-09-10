require "test_helper"

class HistoricalProposalReviewsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @conversation = conversations(:reviewing_conversation)
    @record = @conversation.historical_proposals.create!(
      source_sha256: SecureRandom.hex(32), origin: "revisao_manual", job_name: "PTC26099",
      job_number: "PTC26099", client_name: @conversation.client_name, source_path: "active_storage:x",
      relative_path: "proposta_revisada.docx", filename: "proposta_revisada.docx", chunker_version: "1",
      role: "proposta_papyrus", role_source: "consultor", status: "ok", review_status: "pending",
      pending_text: "1. OBJETIVO DOS SERVIÇOS\n\n#{'Elaboração de estudo ambiental. ' * 10}"
    )
    sign_in_as users(:one)
  end

  test "aprovar torna o documento recuperável no acervo" do
    stub_embedder { post approve_conversation_historical_proposal_path(@conversation, @record) }

    assert @record.reload.approved?
    assert_equal users(:one), @record.submitted_by
    assert HistoricalProposalChunk.embedded.exists?(historical_proposal: @record)
  end

  test "rejeitar mantém o documento fora do acervo" do
    post reject_conversation_historical_proposal_path(@conversation, @record)

    assert @record.reload.rejected?
    assert_not HistoricalProposalChunk.embedded.exists?(historical_proposal: @record)
  end

  test "falha ao embedar deixa o registro pendente para tentar de novo" do
    original = Rag::Embedder.instance_method(:embed_documents)
    Rag::Embedder.define_method(:embed_documents) { |_| raise Rag::Embedder::Error, "Bedrock fora" }

    post approve_conversation_historical_proposal_path(@conversation, @record)

    assert @record.reload.pending?, "aprovado sem vetor seria inencontrável — melhor continuar pendente"
    assert_redirected_to @conversation
  ensure
    Rag::Embedder.define_method(:embed_documents, original)
  end

  test "não deixa mexer em registro de conversa de outro usuário" do
    outra = Conversation.create!(user: users(:two), client_name: "Outro Cliente", status: "reviewing")
    alheio = outra.historical_proposals.create!(
      source_sha256: SecureRandom.hex(32), origin: "revisao_manual", job_name: "PTC26100",
      client_name: "Outro Cliente", source_path: "active_storage:y", relative_path: "x.docx",
      filename: "x.docx", chunker_version: "1", role: "proposta_papyrus", role_source: "consultor",
      status: "ok", review_status: "pending", pending_text: "sigilo"
    )

    post approve_conversation_historical_proposal_path(outra, alheio)

    assert_response :not_found
    assert alheio.reload.pending?
  end
end
