# "A IA está respondendo" por conversa (2026-09-27, cenário do consultor: pedir a proposta técnica
# e, enquanto gera, mandar outra mensagem pedindo de novo). Marcado de forma atômica ao aceitar a
# mensagem (AiResponding#claim_ai_turn!) e limpo no fim do job — mensagem nova no meio é recusada.
class AddAiRespondingSinceToChats < ActiveRecord::Migration[8.1]
  def change
    add_column :conversations, :ai_responding_since, :datetime
    add_column :general_chats, :ai_responding_since, :datetime
  end
end
