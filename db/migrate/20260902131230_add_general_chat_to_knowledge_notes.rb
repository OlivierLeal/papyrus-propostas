class AddGeneralChatToKnowledgeNotes < ActiveRecord::Migration[8.1]
  def change
    # Uma nota agora pode nascer de uma proposta (conversation) OU do chat geral de dúvidas
    # (general_chat, sem proposta nenhuma) — nunca dos dois, ver validação em KnowledgeNote.
    change_column_null :knowledge_notes, :conversation_id, true
    add_reference :knowledge_notes, :general_chat, foreign_key: true
  end
end
