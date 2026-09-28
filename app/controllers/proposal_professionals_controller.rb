class ProposalProfessionalsController < ApplicationController
  before_action :set_conversation
  before_action :set_pricing
  before_action :require_editable

  def create
    line = @pricing.proposal_professionals.new(line_params)

    if line.save
      @pricing.recalculate!
      redirect_to conversation_proposal_path(@conversation), notice: "#{line.professional.name} adicionado(a) à equipe."
    else
      redirect_to conversation_proposal_path(@conversation), alert: line.errors.full_messages.to_sentence
    end
  end

  def destroy
    line = @pricing.proposal_professionals.find(params[:id])
    unless line.removable?
      redirect_to conversation_proposal_path(@conversation), alert: "#{line.professional.name} faz parte da equipe fixa e não pode ser removido(a)."
      return
    end

    line.destroy
    @pricing.recalculate!

    redirect_to conversation_proposal_path(@conversation), notice: "Linha removida."
  end

  private
    def set_conversation
      @conversation = Conversation.find(params[:conversation_id])
    end

    def set_pricing
      @pricing = @conversation.proposal.project_pricing
    end

    def require_editable
      return if @conversation.proposal.status != "approved"

      redirect_to conversation_proposal_path(@conversation), alert: "Esta proposta já foi aprovada."
    end

    def line_params
      params.require(:proposal_professional).permit(:professional_id, :pricing_item_id, :deliverable_name, :man_hours, :field_days)
    end
end
