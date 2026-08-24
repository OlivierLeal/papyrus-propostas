# Decisão do consultor sobre uma divergência entre documentos (ver ProjectConflict).
#
# O sistema encontra a divergência, mas nunca escolhe o valor: quem decide é sempre uma pessoa, e
# a decisão vira um achado novo com fonte "consultor" — a mais forte que existe.
class ProjectConflictsController < ApplicationController
  before_action :set_conflict

  def resolve
    value = params[:value].to_s.strip
    if value.blank?
      redirect_to @conversation, alert: "Escolha ou escreva o valor correto para registrar a decisão."
      return
    end

    @conflict.resolve!(Current.session.user, value: value, note: params[:note]) if @conflict.open?
    respond_with_conflict
  end

  def dismiss
    @conflict.dismiss!(Current.session.user) if @conflict.open?
    respond_with_conflict
  end

  private

  def set_conflict
    @conversation = Current.session.user.conversations.find(params[:conversation_id])
    @conflict = @conversation.project_conflicts.find(params[:id])
  end

  def respond_with_conflict
    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to @conversation }
    end
  end
end
