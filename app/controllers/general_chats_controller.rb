class GeneralChatsController < ApplicationController
  before_action :set_general_chat, only: :show

  def index
    @general_chats = current_user.general_chats.order(created_at: :desc)
  end

  # Sem tela de setup — diferente de Conversation, o chat geral não precisa de nenhum arquivo
  # nem dado inicial pra existir. Cria e já manda pra tela de conversa.
  def create
    @general_chat = current_user.general_chats.create!
    @general_chat.with_instructions(GeneralChat::SYSTEM_INSTRUCTIONS)
    @general_chat.messages.where(role: "system").find_each { |message| message.update!(internal: true) }

    redirect_to @general_chat
  end

  def show
  end

  private
    def set_general_chat
      @general_chat = current_user.general_chats.find(params[:id])
    end
end
