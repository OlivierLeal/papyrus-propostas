class ProposalsController < ApplicationController
  before_action :set_conversation
  before_action :set_proposal, only: %i[ show update approve add_external_cost remove_external_cost ]

  def show
    @professionals = Professional.active.order(:name)
    @proposal.project_pricing.proposal_professionals.includes(:professional).load
  end

  def create
    if @conversation.status != "reviewing"
      redirect_to @conversation, alert: "A proposta só pode ser precificada depois da revisão."
      return
    end

    if @conversation.study_type.blank?
      redirect_to @conversation, alert: "Defina o tipo de estudo antes de avançar para a precificação."
      return
    end

    @conversation.ensure_proposal!

    redirect_to conversation_proposal_path(@conversation),
      notice: "Equipe sugerida pela IA com base no TR e nos documentos complementares. Revise as horas antes de aprovar."
  end

  def update
    if editable?
      pricing = @proposal.project_pricing

      if pricing.update(pricing_params) && @proposal.update(document_split_params)
        pricing.recalculate!
        @proposal.update!(status: "priced")
        redirect_to conversation_proposal_path(@conversation), notice: "Preço recalculado."
      else
        errors = (pricing.errors.full_messages + @proposal.errors.full_messages).to_sentence
        redirect_to conversation_proposal_path(@conversation), alert: errors
      end
    else
      redirect_to conversation_proposal_path(@conversation), alert: "Esta proposta já foi aprovada."
    end
  end

  def approve
    if editable?
      @proposal.update!(status: "approved")
      @conversation.update!(status: "completed")
      redirect_to conversation_proposal_path(@conversation), notice: "Preço aprovado."
    else
      redirect_to conversation_proposal_path(@conversation), alert: "Esta proposta já foi aprovada."
    end
  end

  def add_external_cost
    description = params[:description].to_s.strip
    value = params[:value].to_f

    if description.blank? || value <= 0
      redirect_to conversation_proposal_path(@conversation), alert: "Informe descrição e valor do custo externo."
      return
    end

    pricing = @proposal.project_pricing
    pricing.external_costs = pricing.external_costs + [ { "description" => description, "value" => value } ]
    pricing.save!
    pricing.recalculate!

    redirect_to conversation_proposal_path(@conversation), notice: "Custo externo adicionado."
  end

  def remove_external_cost
    pricing = @proposal.project_pricing
    costs = pricing.external_costs.dup
    costs.delete_at(params[:index].to_i)
    pricing.external_costs = costs
    pricing.save!
    pricing.recalculate!

    redirect_to conversation_proposal_path(@conversation), notice: "Custo externo removido."
  end

  private
    def set_conversation
      @conversation = Conversation.find(params[:conversation_id])
    end

    def set_proposal
      @proposal = @conversation.proposal
    end

    def editable?
      @proposal.status != "approved"
    end

    def pricing_params
      params.require(:project_pricing).permit(
        :bdi, :tax_multiplier, :distance_km, :logistics_days, :rental_per_day, :meal_per_day, :fuel_total,
        proposal_professionals_attributes: %i[ id hours_office hours_field ]
      )
    end

    def document_split_params
      params.fetch(:proposal, {}).permit(:document_split)
    end
end
