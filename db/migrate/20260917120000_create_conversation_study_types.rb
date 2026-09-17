class CreateConversationStudyTypes < ActiveRecord::Migration[8.1]
  def up
    create_table :conversation_study_types do |t|
      t.references :conversation, null: false, foreign_key: true
      t.references :study_type, null: false, foreign_key: true
      t.timestamps
    end
    add_index :conversation_study_types, [ :conversation_id, :study_type_id ], unique: true,
      name: "index_conversation_study_types_on_conversation_and_study_type"

    # Backfill: uma proposta pode exigir vários estudos ao mesmo tempo, ou nenhum (2026-09) —
    # conversations.study_type_id (FK única) vira conversation_study_types (N:N). Preserva o
    # vínculo de toda conversa que já tinha um study_type_id preenchido antes de a coluna ser
    # removida (ver migration seguinte).
    execute <<~SQL.squish
      INSERT INTO conversation_study_types (conversation_id, study_type_id, created_at, updated_at)
      SELECT id, study_type_id, NOW(), NOW()
      FROM conversations
      WHERE study_type_id IS NOT NULL
    SQL
  end

  def down
    drop_table :conversation_study_types
  end
end
