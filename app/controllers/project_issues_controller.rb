# Resposta do consultor a uma pendência (ProjectIssue): responder, ou "seguir sem resposta" com
# motivo. As duas liberam a geração da proposta; a resposta vira dado pra IA usar no texto, e a
# liberação vira ressalva. Conversa não é escopada por consultor (mais de um acompanha a mesma
# proposta — ver CLAUDE.md seção 4), então qualquer um pode responder.
class ProjectIssuesController < ApplicationController
  before_action :set_issue

  def answer
    unless @issue.open? && @issue.answer!(Current.session.user, params[:answer])
      return redirect_to(@conversation, alert: "Escreva a resposta.") if @issue.open?
    end
    respond_with_issue
  end

  def waive
    unless @issue.open? && @issue.waive!(Current.session.user, params[:reason])
      return redirect_to(@conversation, alert: "Escreva o motivo para seguir sem resposta.") if @issue.open?
    end
    respond_with_issue
  end

  private

  def set_issue
    @conversation = Conversation.find(params[:conversation_id])
    @issue = @conversation.project_issues.find(params[:id])
  end

  def respond_with_issue
    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to @conversation }
    end
  end
end
