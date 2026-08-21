class RespondToMessageJob < ApplicationJob
  queue_as :default

  def perform(conversation_id)
    conversation = Conversation.find(conversation_id)
    conversation.refresh_proposal_state_snapshot!
    # Sempre registrada, mesmo sem proposal ainda — ela cria a proposta sozinha na primeira vez
    # que é chamada de verdade (ver GenerateProposalDocumentTool#execute/Conversation#ensure_
    # proposal!), então não depende mais do consultor clicar em "Avançar para Precificação" antes.
    conversation.with_tool(GenerateProposalDocumentTool.new(conversation: conversation))
    conversation.with_tool(AddExternalCostTool.new(proposal: conversation.proposal)) if conversation.proposal
    # Consulta ao acervo histórico (CLAUDE.md seção 11.1). Só é registrada quando há acervo
    # indexado — sem isso a IA "descobre" uma ferramenta que sempre volta vazia e passa a
    # mencionar buscas que não trouxeram nada.
    conversation.with_tool(SearchHistoricalArchiveTool.new) if HistoricalProposalChunk.embedded.exists?
    conversation.complete

    message = conversation.messages.where(role: "assistant", internal: false).order(:created_at).last
    return unless message

    conversation.broadcast_remove_to conversation, target: "typing_indicator"
    conversation.broadcast_append_to conversation, target: "messages", partial: "conversations/message",
      locals: { message: message, animate: true }
  rescue StandardError => e
    Rails.logger.error("RespondToMessageJob failed for conversation #{conversation_id}: #{e.class} #{e.message}")
    return unless conversation

    conversation.broadcast_remove_to conversation, target: "typing_indicator"
    conversation.broadcast_append_to conversation, target: "messages", partial: "conversations/error_bubble",
      locals: { text: error_text_for(e) }
  end

  private
    # Não persiste como Message — isso entraria no histórico enviado de volta pra IA em toda
    # chamada futura (ver Conversation#to_llm). É só um aviso visual, some se a página recarregar.
    def error_text_for(error)
      return "Não consegui responder agora — o limite de requisições da IA foi atingido. Tente novamente em alguns minutos." if error.is_a?(RubyLLM::RateLimitError)

      "Não consegui responder agora. Tente novamente em instantes."
    end
end
