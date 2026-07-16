class MessagesController < ApplicationController
  before_action :set_conversation

  def create
    unless @conversation.status.in?(%w[reviewing pricing completed])
      redirect_to @conversation, alert: "Aguarde o processamento terminar antes de continuar a conversa."
      return
    end

    content = params[:content].to_s.strip

    if content.present?
      @conversation.ask(content)
    end

    redirect_to @conversation
  rescue RubyLLM::Error => e
    redirect_to @conversation, alert: "Erro ao consultar a IA: #{e.message}"
  end

  private
    def set_conversation
      @conversation = current_user.conversations.find(params[:conversation_id])
    end
end
