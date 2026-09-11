class AddUserToMessagesAndGeneralMessages < ActiveRecord::Migration[8.1]
  def change
    # Quem digitou a mensagem, pra mostrar o nome de cada consultor no chat (2026-09, pedido do
    # consultor — mais de uma pessoa pode acompanhar/participar da mesma proposta). Opcional: só
    # mensagens role "user" criadas a partir daqui ganham isso (Message/GeneralMessage#before_
    # create); mensagens antigas, da IA, de ferramenta, ou "user" internas do ask_internally
    # (nenhum humano "digitou" aquilo) ficam sem — a view cai pro rótulo genérico "Você" quando
    # não há usuário gravado.
    add_reference :messages, :user, foreign_key: true, null: true
    add_reference :general_messages, :user, foreign_key: true, null: true
  end
end
