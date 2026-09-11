# Roda Proposal#elect_schedule_key_points! FORA da conversa que pediu a geração — mesmo motivo de
# SuggestScheduleJob (GenerateProposalDocumentTool só é chamada como tool call dentro de
# Conversation#complete; rodar a chamada de IA síncrona ali dentro reentraria complete/
# ask_internally). Diferença: SuggestScheduleJob MONTA o cronograma quando não há item nenhum;
# este só ELEGE os ≤6 marcos do infográfico a partir de um cronograma que já existe (proposta
# antiga, ou montado à mão na Tela de Precificação). Ver CLAUDE.md seção 8.
class ElectScheduleKeyPointsJob < ApplicationJob
  queue_as :default

  def perform(proposal_id)
    proposal = Proposal.find_by(id: proposal_id)
    return unless proposal

    pricing = proposal.project_pricing
    return unless pricing
    return if pricing.schedule_key_points.present? # outra geração pode ter chegado primeiro
    return unless pricing.schedule_items.for_type("servico").exists?

    proposal.elect_schedule_key_points!
    proposal.conversation.broadcast_refresh
  rescue StandardError => e
    Rails.logger.error("ElectScheduleKeyPointsJob failed for proposal #{proposal_id}: #{e.class} #{e.message}")
  end
end
