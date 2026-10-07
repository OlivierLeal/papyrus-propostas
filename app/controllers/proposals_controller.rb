class ProposalsController < ApplicationController
  before_action :set_conversation
  before_action :set_proposal, only: %i[ show update approve reopen suggest_logistics rebuild_from_client_sheet add_external_cost remove_external_cost ]

  def show
    @professionals = Professional.active.order(:name)
    # Proposta criada antes de o valor da hora-homem/diária ser preenchido (ou alterado) em
    # Configurações ficava com o subtotal antigo gravado — refaz a conta ao abrir. Aprovada não:
    # preço aprovado fica congelado.
    @proposal.project_pricing.recalculate! if editable? && @proposal.project_pricing.stale_subtotals?
    @precedent_matches = precedent_matches
    @proposal.project_pricing.proposal_professionals.includes(:professional, :pricing_item).load
  end

  def create
    if @conversation.status != "reviewing"
      redirect_to @conversation, alert: "A proposta só pode ser precificada depois da revisão."
      return
    end

    if @conversation.framing_confirmation_required?
      redirect_to @conversation, alert: "Confirme o enquadramento (licença e estudo) no painel antes de precificar."
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
        # Local do projeto mudou na tela: refaz distância/dias de viagem (suggest_logistics! já recalcula).
        pricing.suggest_logistics! if pricing.saved_change_to_ibge_municipality_id?
        anchor = PricingStructure.new(pricing, new_item_name: params[:new_item_name]).apply(params[:structure_action])
        pricing.recalculate!
        @proposal.update!(status: "priced")
        redirect_to conversation_proposal_path(@conversation, anchor: anchor), notice: anchor ? nil : "Preço recalculado."
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
      @proposal.approve!
      # A partir daqui a proposta é documento revisado por humano, então pode virar referência
      # para as próximas (ver IndexApprovedProposalJob).
      IndexApprovedProposalJob.perform_later(@proposal.id)
      redirect_to conversation_proposal_path(@conversation), notice: "Preço aprovado."
    else
      redirect_to conversation_proposal_path(@conversation), alert: "Esta proposta já foi aprovada."
    end
  end

  def reopen
    if editable?
      redirect_to conversation_proposal_path(@conversation), alert: "Esta proposta não está aprovada."
      return
    end

    before, after = @proposal.reopen!(user: current_user, reason: params[:reason])
    notice = "Precificação reaberta — ajuste o que precisar e aprove de novo."
    if before != after
      notice += " Atenção: o valor da hora-homem/diária mudou no cadastro desde a aprovação, " \
                "e o preço foi recalculado de #{helpers.brl(before)} para #{helpers.brl(after)}."
    end
    redirect_to conversation_proposal_path(@conversation), notice: notice
  end

  # Refaz itens e equipe espelhando a lista de preços do cliente (RebuildPricingFromClientSheetJob).
  def rebuild_from_client_sheet
    return redirect_to(conversation_proposal_path(@conversation), alert: "Esta proposta já foi aprovada.") unless editable?

    RebuildPricingFromClientSheetJob.perform_later(@proposal.id)
    redirect_to conversation_proposal_path(@conversation),
      notice: "Reorganizando a precificação pela planilha do cliente (cerca de 1 minuto). A conversa avisa quando terminar — recarregue esta tela depois."
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
    # `kind` só chega da tela ("terceirizado", ver formulário de Serviços Terceirizados) — nunca
    # da IA (AddExternalCostTool não manda esse parâmetro de propósito, ver CLAUDE.md seção 5:
    # "100% responsabilidade dela inserir").
    kind = params[:kind].to_s == "terceirizado" ? "terceirizado" : nil

    if description.blank? || value <= 0
      redirect_to conversation_proposal_path(@conversation), alert: "Informe descrição e valor do custo externo."
      return
    end

    entry = { "description" => description, "value" => value }
    entry["kind"] = kind if kind

    pricing = @proposal.project_pricing
    pricing.external_costs = pricing.external_costs + [ entry ]
    pricing.save!
    pricing.recalculate!

    redirect_to conversation_proposal_path(@conversation), notice: "Custo adicionado."
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

    # Projetos anteriores parecidos (JobPrecedent) pro card de referência da tela. Cacheado por
    # conversa + última mudança nos achados: o descritor só muda quando o escopo muda, e cada
    # busca custa um embedding.
    def precedent_matches
      key = [ "precedents", @conversation.id, @conversation.project_findings.maximum(:updated_at)&.to_i, JobPrecedent.maximum(:updated_at)&.to_i ]
      pairs = Rails.cache.fetch(key, expires_in: 12.hours) do
        Rag::PrecedentFinder.new.call(@conversation.service_descriptor, limit: 3).map { |match| [ match.precedent.id, match.similarity ] }
      end
      records = JobPrecedent.where(id: pairs.map(&:first)).index_by(&:id)
      pairs.filter_map { |id, similarity| Rag::PrecedentFinder::Match.new(precedent: records[id], similarity: similarity) if records[id] }
    rescue StandardError => e
      Rails.logger.warn("[ProposalsController] precedentes indisponíveis: #{e.class} #{e.message}")
      []
    end

    def editable?
      @proposal.status != "approved"
    end

    def pricing_params
      params.require(:project_pricing).permit(
        :bdi, :tax_multiplier, :distance_km, :travel_hours, :daily_km, :municipality_query,
        :rental_per_day, :rental_4x4_per_day, :meal_per_person_per_day, :lodging_per_person_per_night,
        :fuel_price_per_liter, :vehicle_consumption_km_per_liter, :toll_price, :wash_price,
        :uber_price, :mateiro_per_day, :epi_price, :common_split, :price_presentation,
        :schedule_papyrus_start_date, :schedule_empreendimento_start_date,
        payment_dates: [],
        payment_schedule_items: %i[ label percentage date ],
        proposal_professionals_attributes: %i[ id deliverable_name pricing_item_id man_hours field_days man_hours_per_unit field_days_per_unit
                                               fixed_amount rate_man_hour_override rate_daily_override ],
        pricing_enterprises_attributes: %i[ id name ],
        pricing_items_attributes: [
          :id, :name, :pricing_enterprise_id, :client_quantity, { cost_items: %i[ description quantity unit_value ] },
          { field_campaigns_attributes: %i[ id description people days travel_days vehicles vehicle_type
                                            tolls washes uber_trips mateiro_days epi_count municipality_query
                                            lodging_mode lodging_name lodging_price_per_night commute_km commute_hours ] }
        ],
        schedule_items_attributes: %i[ id phase_name activity_name start_period duration_periods milestone ]
      )
    end

    def document_split_params
      params.fetch(:proposal, {}).permit(:document_split)
    end
end
