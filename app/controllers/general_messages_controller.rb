class GeneralMessagesController < ApplicationController
  before_action :set_general_chat

  def create
    content = params[:content].to_s.strip
    documents = Array(params[:documents]).reject(&:blank?)

    if content.present? || documents.any?
      message = @general_chat.create_user_message(content.presence || default_content(documents))
      documents.each { |document| attach_with_kind(message, document, "document") }

      # Mesmo motivo de MessagesController#create: sem isso, só quem enviou vê a mensagem antes da
      # página recarregar — outra aba (ou outro consultor, se o chat geral virar compartilhado no
      # futuro) só receberia a resposta da IA depois.
      @general_chat.broadcast_render_to @general_chat,
        partial: "general_chats/user_message_broadcast", locals: { message: message }

      RespondToGeneralChatMessageJob.perform_later(@general_chat.id)
    end

    # turbo_stream só devolve o composer limpo — a mensagem em si já chega via broadcast acima
    # (mesmo padrão de MessagesController#create).
    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to @general_chat }
    end
  end

  private
    def set_general_chat
      @general_chat = current_user.general_chats.find(params[:general_chat_id])
    end

    def default_content(documents)
      "Documento(s) enviado(s): #{documents.map(&:original_filename).join(', ')}."
    end
end
