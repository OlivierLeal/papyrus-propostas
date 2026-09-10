# Aprovação da versão final revisada que a IA propôs guardar no acervo RAG, a pedido do
# consultor no chat (ver LearnFromRevisedProposalTool). Mesmo desenho de
# KnowledgeNotesController: é aqui que o documento deixa de ser "um anexo qualquer" e vira
# referência consultável em propostas futuras — por isso a ação é sempre de um humano.
class HistoricalProposalReviewsController < ApplicationController
  before_action :set_historical_proposal

  def approve
    @historical_proposal.approve!(Current.session.user) if @historical_proposal.pending?
    respond_with_historical_proposal
  rescue StandardError => e
    # Aprovar depende de chunkar+embedar (chamada externa): se falhar, o registro continua
    # pendente e o consultor pode tentar de novo, em vez de ficar aprovado e inencontrável.
    Rails.logger.error("Falha ao aprovar historical_proposal #{@historical_proposal.id}: #{e.class} #{e.message}")
    redirect_to @conversation, alert: "Não consegui guardar esse documento agora. Tente novamente."
  end

  def reject
    @historical_proposal.reject!(Current.session.user) if @historical_proposal.pending?
    respond_with_historical_proposal
  end

  private

  def set_historical_proposal
    @conversation = Current.session.user.conversations.find(params[:conversation_id])
    @historical_proposal = @conversation.historical_proposals.find(params[:id])
  end

  def respond_with_historical_proposal
    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to @conversation }
    end
  end
end
