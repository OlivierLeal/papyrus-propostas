require "test_helper"

class GeneralChatKnowledgeNotesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @general_chat = general_chats(:with_messages)
    @note = @general_chat.knowledge_notes.create!(category: "escopo_metodologia", content: "Regra geral")
    sign_in_as users(:one)
  end

  test "aprovar torna a nota recuperável em propostas futuras" do
    stub_embedder { post approve_general_chat_knowledge_note_path(@general_chat, @note) }

    assert @note.reload.approved?
    assert_equal users(:one), @note.approved_by
    assert KnowledgeNote.searchable.exists?(id: @note.id)
  end

  test "rejeitar mantém a nota fora da busca" do
    post reject_general_chat_knowledge_note_path(@general_chat, @note)

    assert_equal "rejected", @note.reload.status
    assert_not KnowledgeNote.searchable.exists?(id: @note.id)
  end

  test "falha ao embedar deixa a nota pendente para tentar de novo" do
    original = Rag::Embedder.instance_method(:embed_documents)
    Rag::Embedder.define_method(:embed_documents) { |_| raise Rag::Embedder::Error, "Bedrock fora" }

    post approve_general_chat_knowledge_note_path(@general_chat, @note)

    assert @note.reload.pending?, "aprovada sem vetor seria inencontrável — melhor continuar pendente"
    assert_redirected_to @general_chat
  ensure
    Rag::Embedder.define_method(:embed_documents, original)
  end

  test "não deixa mexer em nota de general_chat de outro usuário" do
    outro_chat = users(:two).general_chats.create!
    nota_alheia = outro_chat.knowledge_notes.create!(category: "escopo_metodologia", content: "sigilo")

    post approve_general_chat_knowledge_note_path(outro_chat, nota_alheia)

    assert_response :not_found
    assert nota_alheia.reload.pending?
  end
end
