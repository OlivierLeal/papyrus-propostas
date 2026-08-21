# Aprovação das notas de conhecimento propostas pela IA durante a conversa (ver KnowledgeNote).
#
# É aqui que a informação deixa de ser um palpite registrado e vira conhecimento consultável em
# propostas futuras — por isso a ação é sempre de um humano, nunca da IA.
class KnowledgeNotesController < ApplicationController
  before_action :set_note

  def approve
    @note.approve!(Current.session.user) if @note.pending?
    respond_with_note
  rescue StandardError => e
    # Aprovar depende de gerar o embedding (chamada externa): se falhar, a nota continua
    # pendente e o consultor pode tentar de novo, em vez de ficar aprovada e inencontrável.
    Rails.logger.error("Falha ao aprovar knowledge_note #{@note.id}: #{e.class} #{e.message}")
    redirect_to @conversation, alert: "Não consegui guardar essa informação agora. Tente novamente."
  end

  def reject
    @note.reject!(Current.session.user) if @note.pending?
    respond_with_note
  end

  private

  def set_note
    @conversation = Current.session.user.conversations.find(params[:conversation_id])
    @note = @conversation.knowledge_notes.find(params[:id])
  end

  def respond_with_note
    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to @conversation }
    end
  end
end
