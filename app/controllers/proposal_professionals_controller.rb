class ProposalProfessionalsController < ApplicationController
  before_action :set_conversation
  before_action :set_pricing

  def create
    line = @pricing.proposal_professionals.new(line_params)

    if line.save
      @pricing.recalculate!
      redirect_to conversation_proposal_path(@conversation), notice: "Linha adicionada."
    else
      redirect_to conversation_proposal_path(@conversation), alert: line.errors.full_messages.to_sentence
    end
  end

  def destroy
    line = @pricing.proposal_professionals.find(params[:id])
    line.destroy
    @pricing.recalculate!

    redirect_to conversation_proposal_path(@conversation), notice: "Linha removida."
  end

  private
    def set_conversation
      @conversation = current_user.conversations.find(params[:conversation_id])
    end

    def set_pricing
      @pricing = @conversation.proposal.project_pricing
    end

    def line_params
      params.require(:proposal_professional).permit(:professional_id, :deliverable_name, :hours_office, :hours_field)
    end
end
