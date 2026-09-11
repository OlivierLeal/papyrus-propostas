# Roda Proposal#build_with_ai_suggested_schedule! FORA da conversa que pediu a geração —
# GenerateProposalDocumentTool só é chamada como tool call dentro de Conversation#complete
# (RespondToMessageJob), então rodar a sugestão SÍNCRONA ali dentro (como antes) reentrava
# Conversation#complete/#ask_internally enquanto o de fora ainda estava no meio da própria
# chamada de tool — achado ao vivo (conversa 32/proposta 18): a chamada de verdade ao Bedrock
# falhava sozinha ("RubyLLM: API call failed, destroying message"), sem exceção nenhuma pro
# rescue de build_with_ai_suggested_schedule! pegar, e o cronograma ficava vazio pra sempre,
# mesmo com GenerateProposalDocumentTool#ensure_schedule_suggested! tentando de novo a cada
# geração. Ver CLAUDE.md seção 8.
#
# `with_schedule_lock` (ver Proposal) serializa contra outro job concorrente pra MESMA proposta —
# sem ela, duas chamadas de "gerar cronograma" próximas no tempo enfileiravam duas instâncias
# deste job, as duas passavam pela checagem "já existe item?" antes de qualquer uma ter tido
# tempo de chamar a IA (que leva dezenas de segundos), e as duas construíam o cronograma inteiro
# em paralelo — resultado real, achado ao vivo no chat 32: toda atividade duplicada numa
# paráfrase diferente.
class SuggestScheduleJob < ApplicationJob
  queue_as :default

  def perform(proposal_id)
    proposal = Proposal.find_by(id: proposal_id)
    return unless proposal
    return unless proposal.project_pricing

    built = false
    proposal.with_schedule_lock do
      # `.exists?` numa association has_many sempre bate no banco (não usa cache de Ruby, ao
      # contrário do has_one `project_pricing` — ver o `.reload` equivalente em
      # ElectScheduleKeyPointsJob), então não precisa de reload aqui: mesmo com `project_pricing`
      # carregado ANTES da trava, esta checagem enxerga o commit da outra chamada corretamente.
      next if proposal.project_pricing.schedule_items.exists? # outra geração já chegou primeiro

      proposal.build_with_ai_suggested_schedule!
      built = true
    end
    proposal.conversation.broadcast_refresh if built
  rescue StandardError => e
    Rails.logger.error("SuggestScheduleJob failed for proposal #{proposal_id}: #{e.class} #{e.message}")
  end
end
