# Roda Proposal#elect_schedule_key_points! FORA da conversa que pediu a geração — mesmo motivo de
# SuggestScheduleJob (GenerateProposalDocumentTool só é chamada como tool call dentro de
# Conversation#complete; rodar a chamada de IA síncrona ali dentro reentraria complete/
# ask_internally). Diferença: SuggestScheduleJob MONTA o cronograma quando não há item nenhum;
# este só ELEGE os ≤6 marcos do infográfico a partir de um cronograma que já existe (proposta
# antiga, ou montado à mão na Tela de Precificação). Ver CLAUDE.md seção 8.
#
# Mesma trava de SuggestScheduleJob (`Proposal#with_schedule_lock`), mesmo motivo: sem ela, duas
# chamadas próximas no tempo passavam as duas pela checagem "já elegeu?" antes de qualquer uma
# terminar de chamar a IA, e rodavam duas sugestões em paralelo — aqui não duplica linha (é um
# `update!` só, a última vence), mas gasta uma chamada de IA à toa e o resultado final depende de
# corrida, então mesma correção por consistência.
class ElectScheduleKeyPointsJob < ApplicationJob
  queue_as :default

  def perform(proposal_id)
    proposal = Proposal.find_by(id: proposal_id)
    return unless proposal
    return unless proposal.project_pricing

    elected = false
    proposal.with_schedule_lock do
      # .reload, não só `project_pricing`: has_one memoiza o registro carregado no `return unless
      # proposal.project_pricing` acima (ANTES da trava) — sem forçar releitura aqui, a segunda
      # chamada, ao acordar depois do commit da primeira, ainda enxergaria `schedule_key_points`
      # como estava antes de entrar na fila (vazio), e chamaria a IA de novo à toa.
      pricing = proposal.project_pricing.reload
      next if pricing.schedule_key_points.present? # outra geração já chegou primeiro
      next unless pricing.schedule_items.for_type("servico").exists?

      proposal.elect_schedule_key_points!
      elected = true
    end
    proposal.conversation.broadcast_refresh if elected
  rescue StandardError => e
    Rails.logger.error("ElectScheduleKeyPointsJob failed for proposal #{proposal_id}: #{e.class} #{e.message}")
  end
end
