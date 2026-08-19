class MessagesController < ApplicationController
  before_action :set_conversation

  def create
    unless @conversation.status.in?(%w[reviewing pricing completed])
      redirect_to @conversation, alert: "Aguarde o processamento terminar antes de continuar a conversa."
      return
    end

    content = params[:content].to_s.strip
    documents = Array(params[:documents]).reject(&:blank?)

    if content.present? || documents.any?
      message = @conversation.create_user_message(content.presence || default_content(documents))
      documents.each { |document| attach_with_kind(message, document, "complementary") }

      # Sem isso, quem manda a mensagem só a vê porque a página inteira recarrega — outras abas
      # (ou outro consultor olhando a mesma proposta) nunca recebem essa mensagem via WebSocket,
      # só a resposta da IA depois (que o RespondToMessageJob transmite).
      @conversation.broadcast_append_to @conversation, target: "messages", partial: "conversations/message", locals: { message: message }
      @conversation.broadcast_append_to @conversation, target: "messages", partial: "conversations/typing_indicator"

      RespondToMessageJob.perform_later(@conversation.id)
    end

    # turbo_stream (padrão dos forms com Turbo habilitado) só devolve o composer limpo — a
    # mensagem em si já chega pra esta mesma aba via broadcast acima (WebSocket), sem precisar
    # navegar a página inteira de novo. html continua existindo como fallback (JS desabilitado,
    # ou os testes que ainda fazem POST simples).
    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to @conversation }
    end
  end

  private
    def set_conversation
      @conversation = Conversation.find(params[:conversation_id])
    end

    def default_content(documents)
      "Documento(s) complementar(es) enviado(s): #{documents.map(&:original_filename).join(', ')}."
    end
end
