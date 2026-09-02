class CreateGeneralChats < ActiveRecord::Migration[8.1]
  def change
    create_table :general_chats do |t|
      t.references :user, null: false, foreign_key: true
      # Preenchido a partir da primeira mensagem do consultor (ver GeneralChat#display_title) —
      # nunca digitado na criação, o chat geral não tem uma tela de setup como Conversation.
      t.string :title

      t.timestamps
    end
  end
end
