class RespondToGeneralChatMessageJob < ApplicationJob
  queue_as :default

  def perform(general_chat_id)
    general_chat = GeneralChat.find(general_chat_id)

    # Mesmas duas ferramentas de embasamento do chat de proposta (CLAUDE.md seção 11.1/11.2) — sem
    # GenerateProposalDocumentTool, AddExternalCostTool nem RememberForFutureProposalsTool, porque
    # não existe proposta nem projeto associado a este chat.
    general_chat.with_tool(SearchHistoricalArchiveTool.new) if HistoricalProposalChunk.embedded.exists?
    general_chat.with_tool(SearchLegalNormsTool.new) if Cal::Client.configured?
    general_chat.complete

    general_chat.update!(title: general_chat.display_title) if general_chat.title.blank?

    message = general_chat.messages.where(role: "assistant", internal: false).order(:created_at).last
    return unless message

    general_chat.broadcast_remove_to general_chat, target: "typing_indicator"
    general_chat.broadcast_append_to general_chat, target: "messages", partial: "general_chats/message",
      locals: { message: message, animate: true }
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
