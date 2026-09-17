# Roda DEPOIS de CreateConversationStudyTypes (que já fez o backfill) — o vínculo de toda
# conversa que tinha um study_type_id preenchido já existe em conversation_study_types antes
# desta coluna sumir.
class RemoveStudyTypeIdFromConversations < ActiveRecord::Migration[8.1]
  def change
    remove_reference :conversations, :study_type, foreign_key: true, index: true
  end
end
