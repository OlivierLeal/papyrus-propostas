# Decisão do consultor sobre o TR do estudo que o sistema encontrou (TermOfReferenceCandidate):
# aceitar (vira o Anexo I e é lido como TR) ou descartar. Sempre ação de gente, nunca da IA.
class TermOfReferenceCandidatesController < ApplicationController
  before_action :set_candidate

  def accept
    @candidate.accept!(Current.session.user) if @candidate.pending? || @candidate.failed?
    respond_with_card
  end

  def reject
    @candidate.reject!(Current.session.user) if @candidate.pending? || @candidate.failed?
    respond_with_card
  end

  private

  def set_candidate
    # Qualquer consultor decide (a proposta não é de um só — CLAUDE.md seção 4).
    @conversation = Conversation.find(params[:conversation_id])
    @candidate = @conversation.term_of_reference_candidates.find(params[:id])
  end

  def respond_with_card
    respond_to do |format|
      format.turbo_stream { render turbo_stream: turbo_stream.replace(helpers.dom_id(@candidate), partial: "term_of_reference_candidates/card", locals: { candidate: @candidate }) }
      format.html { redirect_to @conversation }
    end
  end
end
