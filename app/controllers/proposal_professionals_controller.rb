class ProposalProfessionalsController < ApplicationController
  before_action :set_conversation
  before_action :set_pricing
  before_action :require_editable

  def create
    line = @pricing.proposal_professionals.new(line_params)
    saved = ProposalProfessional.transaction do
      line.pricing_item = create_new_item!(line) if line_params[:pricing_item_id] == "new"
      (line.errors.empty? && line.save) || raise(ActiveRecord::Rollback)
    end

    if saved
      @pricing.recalculate!
      verb = params[:restored].present? ? "de volta à" : "adicionado(a) à"
      # Volta pro item onde a pessoa entrou (proposta 69: com muitas OS, a tela voltava pro topo).
      redirect_to conversation_proposal_path(@conversation, anchor: "equipe-item-#{line.pricing_item_id}"),
        notice: "#{line.professional.name} #{verb} equipe#{" (#{line.pricing_item.name})" if line.pricing_item}."
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

    # Desfazer (Charlene, 2026-10: "qd excluimos alguém, não conseguimos desfazer"): a faixa da aba
    # Equipe recria a linha igual, pelo mesmo create.
    flash[:removed_line] = { "name" => line.professional.name, "attributes" => line.slice(*RESTORABLE).compact.transform_values(&:to_s) }
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

    # "+ Novo item…" no seletor (2026-10): cria o item com o nome digitado, na mesma transação da
    # linha (rollback desfaz o item se a linha não salvar). Sem nome, a linha não salva.
    def create_new_item!(line)
      name = params[:new_item_name].to_s.strip
      if name.empty?
        line.errors.add(:base, "Informe o nome do novo item")
        return
      end

      @pricing.pricing_items.create!(name: name, position: @pricing.pricing_items.maximum(:position).to_i + 1)
    end

    RESTORABLE = %w[professional_id pricing_item_id deliverable_name man_hours field_days man_hours_per_unit field_days_per_unit
                    fixed_amount rate_man_hour_override rate_daily_override].freeze

    def line_params
      params.require(:proposal_professional).permit(*RESTORABLE)
    end
end
