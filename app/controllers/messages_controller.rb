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
      @conversation.complete
    end

    redirect_to @conversation
  rescue RubyLLM::Error => e
    redirect_to @conversation, alert: "Erro ao consultar a IA: #{e.message}"
  end

  private
    def set_conversation
      @conversation = current_user.conversations.find(params[:conversation_id])
    end

    def default_content(documents)
      "Documento(s) complementar(es) enviado(s): #{documents.map(&:original_filename).join(', ')}."
    end
end
