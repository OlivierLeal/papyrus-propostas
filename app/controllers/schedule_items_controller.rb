# Linhas do cronograma (fase/atividade/período) editadas manualmente na Tela de Precificação —
# ver ScheduleItem/Proposal#build_with_ai_suggested_schedule!. Diferente de
# ProposalProfessionalsController/custos externos (que não checam status "approved" no
# controller, só escondem os controles na view), aqui a checagem é explícita: decisão consciente
# pra não herdar o gap num controller novo.
class ScheduleItemsController < ApplicationController
  before_action :set_conversation
  before_action :set_pricing

  def create
    unless editable?
      redirect_to conversation_proposal_path(@conversation), alert: "Esta proposta já foi aprovada."
      return
    end

    line = @pricing.schedule_items.new(line_params.merge(position: next_position))

    if line.save
      redirect_to conversation_proposal_path(@conversation), notice: "Item do cronograma adicionado."
    else
      redirect_to conversation_proposal_path(@conversation), alert: line.errors.full_messages.to_sentence
    end
  end

  def destroy
    unless editable?
      redirect_to conversation_proposal_path(@conversation), alert: "Esta proposta já foi aprovada."
      return
    end

    @pricing.schedule_items.find(params[:id]).destroy

    redirect_to conversation_proposal_path(@conversation), notice: "Item do cronograma removido."
  end

  private
    def set_conversation
      @conversation = Conversation.find(params[:conversation_id])
    end

    def set_pricing
      @pricing = @conversation.proposal.project_pricing
    end

    def editable?
      @conversation.proposal.status != "approved"
    end

    # position é só ordem de exibição dentro do MESMO schedule_type — não precisa ser único na
    # tabela toda, só crescente o bastante pra a linha nova cair depois das existentes desse tipo.
    def next_position
      @pricing.schedule_items.where(schedule_type: line_params[:schedule_type]).maximum(:position).to_i + 1
    end

    def line_params
      params.require(:schedule_item).permit(:schedule_type, :phase_name, :activity_name, :start_period, :duration_periods, :milestone)
    end
end
