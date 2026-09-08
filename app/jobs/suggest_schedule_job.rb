# Roda Proposal#build_with_ai_suggested_schedule! FORA da conversa que pediu a geração —
# GenerateProposalDocumentTool só é chamada como tool call dentro de Conversation#complete
# (RespondToMessageJob), então rodar a sugestão SÍNCRONA ali dentro (como antes) reentrava
# Conversation#complete/#ask_internally enquanto o de fora ainda estava no meio da própria
# chamada de tool — achado ao vivo (conversa 32/proposta 18): a chamada de verdade ao Bedrock
# falhava sozinha ("RubyLLM: API call failed, destroying message"), sem exceção nenhuma pro
# rescue de build_with_ai_suggested_schedule! pegar, e o cronograma ficava vazio pra sempre,
# mesmo com GenerateProposalDocumentTool#ensure_schedule_suggested! tentando de novo a cada
# geração. Ver CLAUDE.md seção 8.
class SuggestScheduleJob < ApplicationJob
  queue_as :default

  def perform(proposal_id)
    proposal = Proposal.find_by(id: proposal_id)
    return unless proposal

    pricing = proposal.project_pricing
    return unless pricing
    return if pricing.schedule_items.exists? # outra geração pode ter chegado primeiro

    proposal.build_with_ai_suggested_schedule!
    proposal.conversation.broadcast_refresh
  rescue StandardError => e
    Rails.logger.error("SuggestScheduleJob failed for proposal #{proposal_id}: #{e.class} #{e.message}")
  end
end
