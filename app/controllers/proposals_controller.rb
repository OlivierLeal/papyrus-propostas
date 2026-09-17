class ProposalsController < ApplicationController
  before_action :set_conversation
  before_action :set_proposal, only: %i[ show update approve suggest_logistics add_external_cost remove_external_cost ]

  def show
    @professionals = Professional.active.order(:name)
    @proposal.project_pricing.proposal_professionals.includes(:professional).load
  end

  def create
    if @conversation.status != "reviewing"
      redirect_to @conversation, alert: "A proposta só pode ser precificada depois da revisão."
      return
    end

    @conversation.ensure_proposal!

    redirect_to conversation_proposal_path(@conversation),
      notice: "Equipe sugerida pela IA com base no ET, no TR (quando houver) e nos documentos complementares. Revise as horas antes de aprovar."
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
      # A partir daqui a proposta é documento revisado por humano, então pode virar referência
      # para as próximas (ver IndexApprovedProposalJob).
      IndexApprovedProposalJob.perform_later(@proposal.id)
      redirect_to conversation_proposal_path(@conversation), notice: "Preço aprovado."
    else
      redirect_to conversation_proposal_path(@conversation), alert: "Esta proposta já foi aprovada."
    end
  end

  def suggest_logistics
    if editable?
      @proposal.project_pricing.suggest_logistics!
      pricing = @proposal.project_pricing.reload
      notice = if pricing.distance_km.zero?
        "Não foi possível calcular a distância automaticamente (ainda sem localização do projeto processada)."
      else
        aviso = pricing.long_distance? ? " Distância sugere deslocamento aéreo — lance passagem e locação no destino em Custos Externos." : ""
        "Distância recalculada: #{pricing.distance_km} km (~#{pricing.travel_hours}h de viagem).#{aviso}"
      end
      redirect_to conversation_proposal_path(@conversation), notice: notice
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
        :bdi, :tax_multiplier, :distance_km, :travel_hours, :logistics_days,
        :rental_per_day, :vehicles_count, :meal_per_person_per_day, :lodging_per_person_per_night,
        :fuel_total, :fuel_price_per_liter, :vehicle_consumption_km_per_liter,
        :schedule_papyrus_start_date, :schedule_empreendimento_start_date,
        payment_dates: [],
        proposal_professionals_attributes: %i[ id hours_office hours_field ],
        schedule_items_attributes: %i[ id phase_name activity_name start_period duration_periods milestone ]
      )
    end

    def document_split_params
      params.fetch(:proposal, {}).permit(:document_split)
    end
end
