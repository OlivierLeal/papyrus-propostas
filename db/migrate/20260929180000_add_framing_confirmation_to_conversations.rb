# Trava de confirmação do enquadramento antes de gerar/precificar (2026-09-29, relato da Sara: leu o
# resumo "no automático", pediu pra gerar, e só depois viu que o sistema tinha enquadrado diferente
# da Papyrus — o escopo inteiro saiu no enquadramento errado). Ver Conversation#confirm_framing!.
class AddFramingConfirmationToConversations < ActiveRecord::Migration[8.1]
  def change
    add_column :conversations, :framing_confirmed_at, :datetime
    add_reference :conversations, :framing_confirmed_by, foreign_key: { to_table: :users }
  end
end
