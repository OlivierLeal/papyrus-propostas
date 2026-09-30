# "Reorganizar pela planilha do cliente": refaz itens e equipe espelhando a lista de preços do
# cliente (Proposal#rebuild_team_from_client_sheet!). Background — é chamada de IA — e sob a mesma
# trava da sugestão de equipe, pra não correr junto com um SuggestTeamJob da mesma proposta.
class RebuildPricingFromClientSheetJob < ApplicationJob
  queue_as :default

  MESSAGES = {
    done: "Reorganizei a precificação pela planilha do cliente: %<items>s. Confira o esforço por unidade e preencha o valor dos custos na Tela de Precificação.",
    no_price_list: "Não encontrei uma lista de preços com quantidades entre as planilhas anexadas — a precificação ficou como estava.",
    failed: "Não consegui reorganizar pela planilha do cliente agora — a precificação ficou como estava. Tente de novo em instantes."
  }.freeze

  def perform(proposal_id)
    proposal = Proposal.find_by(id: proposal_id)
    return unless proposal&.project_pricing && proposal.status != "approved"

    result = :failed
    proposal.with_team_lock { result = proposal.rebuild_team_from_client_sheet! }
  rescue StandardError => e
    Rails.logger.error("[RebuildPricingFromClientSheetJob] #{proposal_id}: #{e.class} #{e.message}")
    result = :failed
  ensure
    notify(proposal, result) if proposal
  end

  private

  def notify(proposal, result)
    items = proposal.project_pricing.pricing_items.reload.select(&:mirrored?).map { |item| item.client_label.presence || item.name }
    text = format(MESSAGES.fetch(result || :failed), items: items.to_sentence(last_word_connector: " e "))
    proposal.conversation.messages.create!(role: "assistant", content: text)
    proposal.conversation.broadcast_refresh
  end
end
