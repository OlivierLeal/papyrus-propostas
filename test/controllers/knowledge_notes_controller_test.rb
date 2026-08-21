require "test_helper"

class KnowledgeNotesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @conversation = conversations(:reviewing_conversation)
    @note = @conversation.knowledge_notes.create!(
      category: "preferencia_cliente", content: "Cliente exige proposta em duas partes"
    )
    sign_in_as users(:one)
  end

  test "aprovar torna a nota recuperável em propostas futuras" do
    stub_embedder { post approve_conversation_knowledge_note_path(@conversation, @note) }

    assert @note.reload.approved?
    assert_equal users(:one), @note.approved_by
    assert KnowledgeNote.searchable.exists?(id: @note.id)
  end

  test "rejeitar mantém a nota fora da busca" do
    post reject_conversation_knowledge_note_path(@conversation, @note)

    assert_equal "rejected", @note.reload.status
    assert_not KnowledgeNote.searchable.exists?(id: @note.id)
  end

  test "aprovar duas vezes não reescreve quem aprovou" do
    stub_embedder do
      post approve_conversation_knowledge_note_path(@conversation, @note)
      aprovado_em = @note.reload.approved_at

      post approve_conversation_knowledge_note_path(@conversation, @note)
      assert_equal aprovado_em.to_i, @note.reload.approved_at.to_i
    end
  end

  test "falha ao embedar deixa a nota pendente para tentar de novo" do
    original = Rag::Embedder.instance_method(:embed_documents)
    Rag::Embedder.define_method(:embed_documents) { |_| raise Rag::Embedder::Error, "Bedrock fora" }

    post approve_conversation_knowledge_note_path(@conversation, @note)

    assert @note.reload.pending?, "aprovada sem vetor seria inencontrável — melhor continuar pendente"
    assert_redirected_to @conversation
  ensure
    Rag::Embedder.define_method(:embed_documents, original)
  end

  test "não deixa mexer em nota de conversa de outro usuário" do
    outra = Conversation.create!(user: users(:two), client_name: "Outro Cliente", status: "reviewing")
    nota_alheia = outra.knowledge_notes.create!(category: "preferencia_cliente", content: "sigilo")

    post approve_conversation_knowledge_note_path(outra, nota_alheia)

    assert_response :not_found
    assert nota_alheia.reload.pending?
  end
end
