class GeneralChatsController < ApplicationController
  include Pagy::Method

  before_action :set_general_chat, only: :show

  # Mesmo scroll infinito da Tela de Propostas (ver ConversationsController#index): a 1ª página vem
  # com a tela, as seguintes pelo turbo-frame lazy do fim da lista (general_chats/_page).
  def index
    @pagy, @general_chats = pagy(current_user.general_chats.order(created_at: :desc, id: :desc), limit: ConversationsController::PER_PAGE)

    render :page, layout: false if turbo_frame_request?
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
