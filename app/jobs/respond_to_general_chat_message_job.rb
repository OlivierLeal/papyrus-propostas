class RespondToGeneralChatMessageJob < ApplicationJob
  queue_as :default

  def perform(general_chat_id)
    general_chat = GeneralChat.find(general_chat_id)
    before_message_ids = general_chat.messages.ids

    # Mesmas duas ferramentas de embasamento do chat de proposta (CLAUDE.md seção 11.1/11.2) — sem
    # GenerateProposalDocumentTool nem AddExternalCostTool, que não fazem sentido sem proposta.
    # RememberForFutureProposalsTool vale aqui também: algo dito neste chat pode ajudar em
    # propostas futuras, mesma memória por cliente de sempre (ver KnowledgeNote).
    general_chat.with_tool(SearchHistoricalArchiveTool.new) if HistoricalProposalChunk.embedded.exists?
    general_chat.with_tool(SearchLegalNormsTool.new) if Cal::Client.configured?
    general_chat.with_tool(RememberForFutureProposalsTool.new(general_chat: general_chat))
    general_chat.complete

    general_chat.update!(title: general_chat.display_title) if general_chat.title.blank?

    # Não só a última: RememberForFutureProposalsTool grava uma mensagem assistant PRÓPRIA para o
    # card de aprovação, separada da resposta em texto — sem broadcast dela aqui, o card só
    # aparecia depois de um F5 na página (mesmo motivo de RespondToMessageJob).
    new_messages = general_chat.messages.where(role: "assistant", internal: false)
      .where.not(id: before_message_ids).order(:created_at)
    return if new_messages.none?

    general_chat.broadcast_remove_to general_chat, target: "typing_indicator"
    new_messages.each do |message|
      general_chat.broadcast_append_to general_chat, target: "messages", partial: "general_chats/message",
        locals: { message: message, animate: message == new_messages.last }
    end
  rescue StandardError => e
    Rails.logger.error("RespondToGeneralChatMessageJob failed for general_chat #{general_chat_id}: #{e.class} #{e.message}")
    return unless general_chat

    general_chat.broadcast_remove_to general_chat, target: "typing_indicator"
    general_chat.broadcast_append_to general_chat, target: "messages", partial: "conversations/error_bubble",
      locals: { text: error_text_for(e) }
  end

  private
    def error_text_for(error)
      return "Não consegui responder agora — o limite de requisições da IA foi atingido. Tente novamente em alguns minutos." if error.is_a?(RubyLLM::RateLimitError)

      "Não consegui responder agora. Tente novamente em instantes."
    end
end
