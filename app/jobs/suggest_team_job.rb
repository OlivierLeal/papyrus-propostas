# Roda Proposal#suggest_team_if_missing! FORA da conversa que pediu a geração — mesmo motivo de
# SuggestScheduleJob (GenerateProposalDocumentTool só é chamada como tool call dentro de
# Conversation#complete; rodar a chamada de IA síncrona ali dentro reentraria complete/
# ask_internally). Cobre o caso descoberto em produção: gerar a proposta direto pelo chat (nunca
# passa por ProposalsController, que é o único chamador com ai_suggestions: true) deixava a
# equipe pra sempre só com Diretoria/Coordenação a 0h — parecia "a IA não mapeou a equipe". Ver CLAUDE.md seção 5/13.
#
# `with_team_lock` (ver Proposal) serializa contra outra chamada concorrente pra MESMA proposta —
# sem ela, duas gerações próximas no tempo (mesmo padrão de corrida já visto no cronograma)
# poderiam passar as duas pela checagem "equipe ainda intocada?" antes de qualquer uma ter
# escrito algo, e as duas rodariam a sugestão de equipe em paralelo.
class SuggestTeamJob < ApplicationJob
  queue_as :default

  def perform(proposal_id)
    proposal = Proposal.find_by(id: proposal_id)
    return unless proposal
    return unless proposal.project_pricing

    suggested = false
    proposal.with_team_lock do
      pricing = proposal.project_pricing.reload
      next unless proposal.team_untouched?(pricing)

      proposal.suggest_team_if_missing!
      suggested = true
    end
    if suggested
      proposal.conversation.broadcast_refresh
    end
  rescue StandardError => e
    Rails.logger.error("SuggestTeamJob failed for proposal #{proposal_id}: #{e.class} #{e.message}")
  ensure
    # Sucesso, "nada a fazer" ou falha: sempre avisa, senão uma geração pendente esperaria pra
    # sempre (GenerateProposalDocumentTool.background_task_finished!).
    GenerateProposalDocumentTool.background_task_finished!(proposal, "team") if proposal
  end
end
