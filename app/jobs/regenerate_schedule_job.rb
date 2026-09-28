# Roda Proposal#regenerate_schedule! FORA da conversa que pediu a geração — mesmo motivo de
# SuggestScheduleJob (GenerateProposalDocumentTool só é chamada como tool call dentro de
# Conversation#complete; rodar a chamada de IA síncrona ali dentro reentraria complete/
# ask_internally). Diferença: SuggestScheduleJob só MONTA o cronograma quando não há item nenhum
# (nunca reescreve o que já existe); este SEMPRE apaga e reconstrói — só é enfileirado quando o
# consultor pede explicitamente uma MUDANÇA num cronograma que já existe
# (GenerateProposalDocumentTool param `atualizar_cronograma`). Ver CLAUDE.md seção 8.
#
# Mesma trava de SuggestScheduleJob (`Proposal#with_schedule_lock`) — serializa contra outra
# regeneração/sugestão concorrente pra MESMA proposta, pelo mesmo motivo de sempre: sem ela, duas
# chamadas próximas no tempo poderiam apagar/recriar o cronograma em paralelo, e a última a
# terminar "vence" de forma imprevisível em vez de determinística.
class RegenerateScheduleJob < ApplicationJob
  queue_as :default

  def perform(proposal_id)
    proposal = Proposal.find_by(id: proposal_id)
    return unless proposal
    return unless proposal.project_pricing

    proposal.with_schedule_lock { proposal.regenerate_schedule! }
    proposal.conversation.broadcast_refresh
  rescue StandardError => e
    Rails.logger.error("RegenerateScheduleJob failed for proposal #{proposal_id}: #{e.class} #{e.message}")
  ensure
    # Sucesso, "nada a fazer" ou falha: sempre avisa, senão uma geração pendente esperaria pra
    # sempre (GenerateProposalDocumentTool.background_task_finished!).
    GenerateProposalDocumentTool.background_task_finished!(proposal, "schedule") if proposal
  end
end
