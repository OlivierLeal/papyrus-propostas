require "test_helper"

class KnowledgeNoteTest < ActiveSupport::TestCase
  setup { @conversation = conversations(:reviewing_conversation) }

  test "nasce pendente e fora da busca" do
    note = build_note

    assert note.pending?
    assert_not KnowledgeNote.searchable.exists?(id: note.id),
      "conhecimento não revisado não pode ser recuperado como se fosse fato da Papyrus"
  end

  test "aprovar gera o embedding e torna a nota recuperável" do
    note = build_note

    stub_embedder { note.approve!(users(:one)) }

    assert note.approved?
    assert_equal users(:one), note.approved_by
    assert note.embedding.present?
    assert KnowledgeNote.searchable.exists?(id: note.id)
  end

  test "nota aprovada mas sem embedding não entra na busca" do
    note = build_note
    note.update!(status: "approved", approved_at: Time.current)

    assert_not KnowledgeNote.searchable.exists?(id: note.id),
      "aprovada sem vetor é inencontrável — não pode contar como disponível"
  end

  test "rejeitar não gera embedding nem torna recuperável" do
    note = build_note
    note.reject!(users(:one))

    assert_equal "rejected", note.status
    assert_nil note.embedding
    assert_not KnowledgeNote.searchable.exists?(id: note.id)
  end

  test "o texto embedado carrega categoria e cliente, não só o conteúdo" do
    note = build_note(content: "Coordenador precisa ter doutorado", client_name: "Petrobras")

    assert_includes note.searchable_text, "Petrobras"
    assert_includes note.searchable_text, note.category_label
    assert_includes note.searchable_text, "doutorado"
  end

  test "a citação identifica a memória e o cliente de forma legível" do
    note = build_note(client_name: "Petrobras")
    stub_embedder { note.approve!(users(:one)) }

    assert_match(/memória da Papyrus: correção do consultor · Petrobras/, note.reference)
  end

  test "categoria fora do menu é recusada" do
    note = @conversation.knowledge_notes.build(category: "categoria_inventada", content: "x")

    assert_not note.valid?
    assert_includes note.errors[:category], "não está incluído na lista"
  end

  private

  def build_note(content: "Coordenador temático precisa ter doutorado", client_name: "Petrobras")
    @conversation.knowledge_notes.create!(
      category: "correcao_consultor", content: content, client_name: client_name
    )
  end
end
