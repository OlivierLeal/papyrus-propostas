# Roda Proposal#suggest_team_if_missing! FORA da conversa que pediu a geração — mesmo motivo de
# SuggestScheduleJob (GenerateProposalDocumentTool só é chamada como tool call dentro de
# Conversation#complete; rodar a chamada de IA síncrona ali dentro reentraria complete/
# ask_internally). Cobre o caso descoberto em produção: gerar a proposta direto pelo chat (nunca
# passa por ProposalsController, que é o único chamador com ai_suggestions: true) deixava a
# equipe pra sempre só com Diretoria/Coordenação, pra qualquer tipo de estudo sem study_templates
# cadastrado — parecia "a IA não mapeou a equipe". Ver CLAUDE.md seção 5/13.
#
# `with_team_lock` (ver Proposal) serializa contra outra chamada concorrente pra MESMA proposta —
# sem ela, duas gerações próximas no tempo (mesmo padrão de corrida já visto no cronograma)
# poderiam passar as duas pela checagem "só tem always_included?" antes de qualquer uma ter
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
      next if pricing.proposal_professionals.joins(:professional).where(professionals: { always_included: false }).exists?

      proposal.suggest_team_if_missing!
      suggested = true
    end
    if suggested
      proposal.conversation.broadcast_refresh
      # Mesmo motivo de SuggestScheduleJob: termina sozinho, sem o consultor precisar pedir "gere
      # de novo" depois que a equipe terminar de ser sugerida (CLAUDE.md seção 8).
      GenerateProposalDocumentTool.replay_pending_regeneration!(proposal)
    end
  rescue StandardError => e
    Rails.logger.error("SuggestTeamJob failed for proposal #{proposal_id}: #{e.class} #{e.message}")
  end
end
